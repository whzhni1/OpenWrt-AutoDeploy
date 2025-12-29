#!/bin/bash
# dabao.sh - OpenWrt IPK/APK 打包脚本

set -e

PKG_NAME="$1"
PKG_VERSION="${2#v}"
BIN_DIR="$3"
LUCI_DIR="$4"

# 使用绝对路径
WORK_DIR="$(pwd)"
OUT_DIR="$WORK_DIR/output"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 通用函数
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

do_upx() {
    [ "$PKG_UPX" = "true" ] && upx --best --lzma "$1" 2>/dev/null || true
}

fix_perms() {
    local dir="$1"
    find "$dir" -type f -exec chmod 644 {} \;
    find "$dir" -type f -path "*/bin/*" -exec chmod 755 {} \;
    find "$dir" -type f -path "*/init.d/*" -exec chmod 755 {} \;
    find "$dir" -type f -path "*/uci-defaults/*" -exec chmod 755 {} \;
}

gen_conffiles() {
    [ -z "$PKG_CONFIGS" ] && return 0
    for conf in $PKG_CONFIGS; do echo "$conf"; done > "$1/conffiles"
}

gen_scripts() {
    local ctrl_dir="$1" fmt="$2" service="${BIN_NAME:-$PKG_NAME}"
    
    local post="postinst" pre="prerm"
    [ "$fmt" = "apk" ] && post=".post-install" && pre=".pre-deinstall"
    
    cat > "$ctrl_dir/$post" << EOF
#!/bin/sh
[ -f "/etc/config/$service" ] || exit 0
enabled=\$(uci -q get $service.config.enabled)
[ "\$enabled" = "1" ] && {
    /etc/init.d/$service enable
    /etc/init.d/$service restart
}
exit 0
EOF

    cat > "$ctrl_dir/$pre" << EOF
#!/bin/sh
/etc/init.d/$service disable 2>/dev/null
/etc/init.d/$service stop 2>/dev/null
exit 0
EOF
    chmod 755 "$ctrl_dir/$post" "$ctrl_dir/$pre"
}

do_pack() {
    local pkg="$1" data_dir="$2" ctrl_dir="$3" fmt="$4"
    local pkg_file="$OUT_DIR/${pkg}_${PKG_VERSION}.$fmt"
    local pkg_dir="$TEMP_DIR/pkg_${fmt}_$$"
    
    mkdir -p "$pkg_dir"
    echo "2.0" > "$pkg_dir/debian-binary"
    
    (cd "$ctrl_dir" && tar czf "$pkg_dir/control.tar.gz" ./)
    (cd "$data_dir" && tar czf "$pkg_dir/data.tar.gz" ./)
    (cd "$pkg_dir" && tar czf "$pkg_file" debian-binary control.tar.gz data.tar.gz)
    
    rm -rf "$pkg_dir"
    echo "  📦 $pkg_file"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 二进制打包
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

pack_bin() {
    local bin="$1"
    local bin_name=$(basename "$bin")
    local data_dir="$TEMP_DIR/data_$$" 
    local ctrl_dir="$TEMP_DIR/ctrl_$$"
    
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir/usr/bin" "$ctrl_dir"
    
    do_upx "$bin"
    
    cp "$bin" "$data_dir/usr/bin/${BIN_NAME:-$bin_name}"
    
    for mapping in $EXTRA_FILES; do
        local src="${mapping%%:*}" dst="${mapping##*:}"
        [ -f "$WORK_DIR/$src" ] || continue
        mkdir -p "$data_dir$(dirname "$dst")"
        cp "$WORK_DIR/$src" "$data_dir$dst"
    done
    
    fix_perms "$data_dir"
    
    local size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $bin_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $size
Depends: libc${PKG_DEPS:+, $PKG_DEPS}
Description: $PKG_NAME
EOF
    
    gen_conffiles "$ctrl_dir"
    
    for fmt in ipk apk; do
        gen_scripts "$ctrl_dir" "$fmt"
        do_pack "$bin_name" "$data_dir" "$ctrl_dir" "$fmt"
    done
    
    rm -rf "$data_dir" "$ctrl_dir"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# LuCI 打包
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

build_luci() {
    [ -d "$LUCI_DIR" ] || return 0
    
    local luci_name=$(basename "$LUCI_DIR")
    local data_dir="$TEMP_DIR/luci_data_$$"
    local ctrl_dir="$TEMP_DIR/luci_ctrl_$$"
    
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir" "$ctrl_dir"
    
    [ -d "$LUCI_DIR/root" ] && cp -r "$LUCI_DIR/root/"* "$data_dir/"
    
    [ -d "$LUCI_DIR/luasrc" ] && {
        mkdir -p "$data_dir/usr/lib/lua/luci"
        cp -r "$LUCI_DIR/luasrc/"* "$data_dir/usr/lib/lua/luci/"
    }
    
    [ -d "$LUCI_DIR/htdocs" ] && {
        mkdir -p "$data_dir/www"
        cp -r "$LUCI_DIR/htdocs/"* "$data_dir/www/"
    }
    
    if [ -d "$LUCI_DIR/po" ] && [ -n "$LUCI_LANGS" ]; then
        mkdir -p "$data_dir/usr/lib/lua/luci/i18n"
        for lang in $LUCI_LANGS; do
            if [ -d "$LUCI_DIR/po/$lang" ]; then
                for po in "$LUCI_DIR/po/$lang/"*.po; do
                    [ -f "$po" ] || continue
                    local lmo="${po##*/}"; lmo="${lmo%.po}.$lang.lmo"
                    po2lmo "$po" "$data_dir/usr/lib/lua/luci/i18n/$lmo"
                done
            elif [ -f "$LUCI_DIR/po/$lang.po" ]; then
                po2lmo "$LUCI_DIR/po/$lang.po" "$data_dir/usr/lib/lua/luci/i18n/$luci_name.$lang.lmo"
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
    
    for fmt in ipk apk; do
        gen_scripts "$ctrl_dir" "$fmt"
        do_pack "$luci_name" "$data_dir" "$ctrl_dir" "$fmt"
    done
    
    rm -rf "$data_dir" "$ctrl_dir"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 主流程
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "📦 打包: $PKG_NAME v$PKG_VERSION"

count=0
[ -d "$BIN_DIR" ] && for bin in "$BIN_DIR"/*; do
    [ -f "$bin" ] && { pack_bin "$bin"; ((count++)); }
done
echo "📊 二进制包: $count 个"

[ -n "$LUCI_DIR" ] && build_luci

echo "📁 输出:"
ls -la "$OUT_DIR/"
