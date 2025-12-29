#!/bin/bash
# dabao.sh - OpenWrt IPK/APK 打包脚本

set -e

PKG_NAME="$1"
PKG_VERSION="${2#v}"
BIN_DIR="$3"
LUCI_DIR="$4"

WORK_DIR="$(pwd)"
OUT_DIR="$WORK_DIR/output"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

do_upx() {
    [ "$PKG_UPX" = "true" ] && upx --best --lzma "$1" 2>/dev/null || true
}

fix_perms() {
    find "$1" -type f -exec chmod 644 {} \;
    find "$1" -type f -path "*/bin/*" -exec chmod 755 {} \;
    find "$1" -type f -path "*/init.d/*" -exec chmod 755 {} \;
    find "$1" -type f -path "*/uci-defaults/*" -exec chmod 755 {} \;
}

gen_conffiles() {
    local data_dir="$1" ctrl_dir="$2"
    [ -z "$PKG_CONFIGS" ] && return 0
    for conf in $PKG_CONFIGS; do
        [ -f "$data_dir$conf" ] && echo "$conf"
    done > "$ctrl_dir/conffiles"
    [ -s "$ctrl_dir/conffiles" ] || rm -f "$ctrl_dir/conffiles"
}

gen_scripts() {
    local ctrl_dir="$1" fmt="$2" service="${BIN_NAME:-$PKG_NAME}"
    
    local post="postinst" pre="prerm" postrm="postrm"
    [ "$fmt" = "apk" ] && post=".post-install" && pre=".pre-deinstall" && postrm=".post-deinstall"
    
    # 安装后：先 enable，再根据 enabled 决定 restart 或 stop
    cat > "$ctrl_dir/$post" << EOF
#!/bin/sh
/etc/init.d/$service enable 2>/dev/null
if [ -f "/etc/config/$service" ]; then
    enabled=\$(uci -q get $service.config.enabled)
    if [ "\$enabled" = "1" ]; then
        /etc/init.d/$service restart 2>/dev/null
    else
        /etc/init.d/$service stop 2>/dev/null
    fi
fi
exit 0
EOF

    # 卸载前：停止服务
    cat > "$ctrl_dir/$pre" << EOF
#!/bin/sh
/etc/init.d/$service disable 2>/dev/null
/etc/init.d/$service stop 2>/dev/null
exit 0
EOF

    # 卸载后：删除配置
    cat > "$ctrl_dir/$postrm" << EOF
#!/bin/sh
rm -f /etc/config/$service
rm -rf /etc/$service
exit 0
EOF

    chmod 755 "$ctrl_dir/$post" "$ctrl_dir/$pre" "$ctrl_dir/$postrm"
}

do_pack() {
    local pkg_file="$1" data_dir="$2" ctrl_dir="$3" fmt="$4"
    local pkg_dir="$TEMP_DIR/pkg_${fmt}_$$"
    
    mkdir -p "$pkg_dir"
    echo "2.0" > "$pkg_dir/debian-binary"
    
    # 设置 root 属组
    (cd "$ctrl_dir" && tar --owner=root --group=root -czf "$pkg_dir/control.tar.gz" ./)
    (cd "$data_dir" && tar --owner=root --group=root -czf "$pkg_dir/data.tar.gz" ./)
    (cd "$pkg_dir" && tar --owner=root --group=root -czf "$OUT_DIR/${pkg_file}.$fmt" debian-binary control.tar.gz data.tar.gz)
    
    rm -rf "$pkg_dir"
    echo "  📦 ${pkg_file}.$fmt"
}

pack_bin() {
    local bin="$1"
    local file_name=$(basename "$bin")
    local data_dir="$TEMP_DIR/data_$$" 
    local ctrl_dir="$TEMP_DIR/ctrl_$$"
    local install_name="${BIN_NAME:-$PKG_NAME}"
    
    echo "  🔧 $file_name → $install_name"
    
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir/usr/bin" "$ctrl_dir"
    
    do_upx "$bin"
    
    cp "$bin" "$data_dir/usr/bin/$install_name"
    chmod 755 "$data_dir/usr/bin/$install_name"
    
    fix_perms "$data_dir"
    
    local size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $install_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $size
Depends: libc${PKG_DEPS:+, $PKG_DEPS}
Description: $PKG_NAME
EOF
    
    local pkg_file="${file_name}_${PKG_VERSION}"
    
    for fmt in ipk apk; do
        do_pack "$pkg_file" "$data_dir" "$ctrl_dir" "$fmt"
    done
    
    rm -rf "$data_dir" "$ctrl_dir"
}

build_luci() {
    [ -d "$LUCI_DIR" ] || return 0
    
    local luci_name=$(basename "$LUCI_DIR")
    local data_dir="$TEMP_DIR/luci_data_$$"
    local ctrl_dir="$TEMP_DIR/luci_ctrl_$$"
    
    echo "  🔧 LuCI: $luci_name"
    
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir" "$ctrl_dir"
    
    [ -d "$LUCI_DIR/root" ] && cp -r "$LUCI_DIR/root/"* "$data_dir/"
    
    if [ -d "$LUCI_DIR/luasrc" ]; then
        mkdir -p "$data_dir/usr/lib/lua/luci"
        cp -r "$LUCI_DIR/luasrc/"* "$data_dir/usr/lib/lua/luci/"
    fi
    
    if [ -d "$LUCI_DIR/htdocs" ]; then
        mkdir -p "$data_dir/www"
        cp -r "$LUCI_DIR/htdocs/"* "$data_dir/www/"
    fi
    
    if [ -d "$LUCI_DIR/po" ] && [ -n "$LUCI_LANGS" ]; then
        mkdir -p "$data_dir/usr/lib/lua/luci/i18n"
        for lang in $LUCI_LANGS; do
            if [ -d "$LUCI_DIR/po/$lang" ]; then
                for po in "$LUCI_DIR/po/$lang/"*.po; do
                    [ -f "$po" ] || continue
                    lmo="${po##*/}"; lmo="${lmo%.po}.$lang.lmo"
                    po2lmo "$po" "$data_dir/usr/lib/lua/luci/i18n/$lmo" || true
                done
            elif [ -f "$LUCI_DIR/po/$lang.po" ]; then
                po2lmo "$LUCI_DIR/po/$lang.po" "$data_dir/usr/lib/lua/luci/i18n/$luci_name.$lang.lmo" || true
            fi
        done
    fi
    
    fix_perms "$data_dir"
    
    local size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $luci_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $size
Depends: luci-base${LUCI_DEPS:+, $LUCI_DEPS}
Description: LuCI support for $PKG_NAME
EOF
    
    gen_conffiles "$data_dir" "$ctrl_dir"
    
    local pkg_file="${luci_name}_${PKG_VERSION}"
    
    for fmt in ipk apk; do
        gen_scripts "$ctrl_dir" "$fmt"
        do_pack "$pkg_file" "$data_dir" "$ctrl_dir" "$fmt"
    done
    
    rm -rf "$data_dir" "$ctrl_dir"
}

echo "📦 打包: $PKG_NAME v$PKG_VERSION"

count=0
if [ -d "$BIN_DIR" ]; then
    for bin in "$BIN_DIR"/*; do
        [ -f "$bin" ] && { pack_bin "$bin"; ((count++)) || true; }
    done
fi
echo "📊 二进制包: $count 个"

build_luci

echo "📁 输出:"
ls -la "$OUT_DIR/"
