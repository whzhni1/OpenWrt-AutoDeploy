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
BIN_INSTALL_NAME="${LOCAL_NAME:-$BIN_FILE}"
DISPLAY_NAME="${LOCAL_NAME:-$PKG_NAME}"

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
    local ctrl_dir="$1" fmt="$2"
    local post="postinst" pre="prerm" postrm="postrm"
    [ "$fmt" = "apk" ] && post=".post-install" && pre=".pre-deinstall" && postrm=".post-deinstall"
    
    cat > "$ctrl_dir/$post" << EOF
#!/bin/sh
/etc/init.d/$DISPLAY_NAME enable 2>/dev/null
/etc/init.d/$DISPLAY_NAME restart 2>/dev/null
exit 0
EOF

    cat > "$ctrl_dir/$pre" << EOF
#!/bin/sh
/etc/init.d/$DISPLAY_NAME disable 2>/dev/null
/etc/init.d/$DISPLAY_NAME stop 2>/dev/null
exit 0
EOF

    cat > "$ctrl_dir/$postrm" << EOF
#!/bin/sh
rm -f /etc/config/$DISPLAY_NAME
rm -rf /etc/$DISPLAY_NAME
exit 0
EOF

    chmod 755 "$ctrl_dir/$post" "$ctrl_dir/$pre" "$ctrl_dir/$postrm"
}

do_pack() {
    local pkg_file="$1" data_dir="$2" ctrl_dir="$3" fmt="$4"
    local pkg_dir="$TEMP_DIR/pkg_${fmt}_$$"
    mkdir -p "$pkg_dir"
    echo "2.0" > "$pkg_dir/debian-binary"
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
    local install_name="${BIN_INSTALL_NAME:-$file_name}"
    echo "  🔧 $file_name → /usr/bin/$install_name (Package: $DISPLAY_NAME)"
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir/usr/bin" "$ctrl_dir"
    do_upx "$bin"
    cp "$bin" "$data_dir/usr/bin/$install_name"
    chmod 755 "$data_dir/usr/bin/$install_name"
    fix_perms "$data_dir"
    local size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $DISPLAY_NAME
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
    local luci_base="${luci_name#luci-app-}"
    local data="$TEMP_DIR/luci_data_$$"
    local ctrl="$TEMP_DIR/luci_ctrl_$$"
    
    echo "  🔧 LuCI: $luci_name"
    rm -rf "$data" "$ctrl"
    mkdir -p "$data" "$ctrl"
    
    # luci.mk 标准映射
    [ -d "$LUCI_DIR/root" ] && cp -a "$LUCI_DIR/root/." "$data/"
    [ -d "$LUCI_DIR/htdocs" ] && mkdir -p "$data/www" && cp -a "$LUCI_DIR/htdocs/." "$data/www/"
    [ -d "$LUCI_DIR/luasrc" ] && mkdir -p "$data/usr/lib/lua/luci" && cp -a "$LUCI_DIR/luasrc/." "$data/usr/lib/lua/luci/"
    [ -d "$LUCI_DIR/ucode" ] && mkdir -p "$data/usr/share/ucode/luci" && cp -a "$LUCI_DIR/ucode/." "$data/usr/share/ucode/luci/"
    
    [ -z "$(ls -A "$data" 2>/dev/null)" ] && { rm -rf "$data" "$ctrl"; return 0; }
    fix_perms "$data"
    
    cat > "$ctrl/control" << EOF
Package: $luci_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $(du -sk "$data" | cut -f1)
Depends: luci-base${LUCI_DEPS:+, $LUCI_DEPS}
Description: LuCI support for $PKG_NAME
EOF

    gen_conffiles "$data" "$ctrl"
    
    for fmt in ipk apk; do
        gen_luci_scripts "$ctrl" "$fmt" "$data"
        do_pack "${luci_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"
    done
    rm -rf "$data" "$ctrl"
    
    # 语言包单独打包
    [ -d "$LUCI_DIR/po" ] && build_luci_i18n "$luci_base"
}

gen_luci_scripts() {
    local ctrl="$1" fmt="$2" data="$3"
    local post="postinst" pre="prerm" postrm="postrm"
    [ "$fmt" = "apk" ] && post=".post-install" && pre=".pre-deinstall" && postrm=".post-deinstall"
    
    # 检测是否有 init.d 脚本
    local init_script=$(find "$data/etc/init.d" -type f 2>/dev/null | head -1)
    local svc=""
    [ -n "$init_script" ] && svc=$(basename "$init_script")
    
    cat > "$ctrl/$post" << EOF
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
EOF
    [ -n "$svc" ] && cat >> "$ctrl/$post" << EOF
/etc/init.d/$svc enable 2>/dev/null
/etc/init.d/$svc restart 2>/dev/null
EOF
    echo "exit 0" >> "$ctrl/$post"
    
    if [ -n "$svc" ]; then
        cat > "$ctrl/$pre" << EOF
#!/bin/sh
/etc/init.d/$svc disable 2>/dev/null
/etc/init.d/$svc stop 2>/dev/null
exit 0
EOF
        cat > "$ctrl/$postrm" << EOF
#!/bin/sh
rm -f /etc/config/$svc
rm -rf /etc/$svc
exit 0
EOF
        chmod 755 "$ctrl/$pre" "$ctrl/$postrm"
    fi
    chmod 755 "$ctrl/$post"
}

build_luci_i18n() {
    local luci_base="$1"
    
    for lang_dir in "$LUCI_DIR/po"/*/; do
        [ -d "$lang_dir" ] || continue
        local lang=$(basename "$lang_dir")
        [ "$lang" = "templates" ] && continue
        
        # 语言别名 (luci.mk)
        local lc="$lang"
        case "$lang" in
            zh_Hans) lc="zh-cn" ;; zh_Hant) lc="zh-tw" ;; pt_BR) lc="pt-br" ;;
            bn_BD) lc="bn" ;; nb_NO) lc="no" ;;
        esac
        
        local data="$TEMP_DIR/i18n_data_$$"
        local ctrl="$TEMP_DIR/i18n_ctrl_$$"
        rm -rf "$data" "$ctrl"
        mkdir -p "$data/usr/lib/lua/luci/i18n" "$ctrl"
        
        local has_po=false
        for po in "$lang_dir"*.po; do
            [ -f "$po" ] || continue
            po2lmo "$po" "$data/usr/lib/lua/luci/i18n/$(basename "${po%.po}").${lc}.lmo" 2>/dev/null && has_po=true
        done
        [ "$has_po" = "false" ] && { rm -rf "$data" "$ctrl"; continue; }
        
        fix_perms "$data"
        
        local i18n_name="luci-i18n-${luci_base}-${lc}"
        cat > "$ctrl/control" << EOF
Package: $i18n_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $(du -sk "$data" | cut -f1)
Depends: luci-app-$luci_base
Description: Translation ($lang)
EOF

        for fmt in ipk apk; do
            do_pack "${i18n_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"
        done
        echo "    📦 $i18n_name"
        rm -rf "$data" "$ctrl"
    done
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
