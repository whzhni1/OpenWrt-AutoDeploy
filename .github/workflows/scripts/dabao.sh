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
    find "$1" -type f -path "*/sbin/*" -exec chmod 755 {} \;
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

gen_luci_scripts() {
    local ctrl_dir="$1" fmt="$2"
    
    local post="postinst" postrm="postrm"
    [ "$fmt" = "apk" ] && post=".post-install" && postrm=".post-deinstall"
    
    cat > "$ctrl_dir/$post" << EOF
#!/bin/sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
exit 0
EOF

    cat > "$ctrl_dir/$postrm" << EOF
#!/bin/sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
exit 0
EOF

    chmod 755 "$ctrl_dir/$post" "$ctrl_dir/$postrm"
}

do_pack() {
    local pkg_file="$1" data_dir="$2" ctrl_dir="$3" fmt="$4"
    local pkg_dir="$TEMP_DIR/pkg_${fmt}_$$_$RANDOM"
    
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

build_i18n() {
    local luci_name="$1" lang="$2" lmo_file="$3"
    local data_dir="$TEMP_DIR/i18n_data_${lang}_$$"
    local ctrl_dir="$TEMP_DIR/i18n_ctrl_${lang}_$$"
    
    # 语言代码转换：zh_Hans → zh-hans
    local lang_pkg=$(echo "$lang" | tr '_' '-' | tr 'A-Z' 'a-z')
    local pkg_name="luci-i18n-${luci_name#luci-app-}-${lang_pkg}"
    
    rm -rf "$data_dir" "$ctrl_dir"
    mkdir -p "$data_dir/usr/lib/lua/luci/i18n" "$ctrl_dir"
    
    cp "$lmo_file" "$data_dir/usr/lib/lua/luci/i18n/"
    
    fix_perms "$data_dir"
    
    local size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $pkg_name
Version: $PKG_VERSION
Architecture: all
Installed-Size: $size
Depends: $luci_name
Description: Translation for $luci_name
EOF
    
    local pkg_file="${pkg_name}_${PKG_VERSION}"
    
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
    
    # 复制所有文件，排除不需要的
    for item in "$LUCI_DIR"/*; do
        [ -e "$item" ] || continue
        name=$(basename "$item")
        case "$name" in
            Makefile|.git*|README*|LICENSE*|po|*.md|*.txt) continue ;;
        esac
        
        if [ "$name" = "root" ]; then
            cp -a "$item/." "$data_dir/"
        elif [ "$name" = "htdocs" ]; then
            mkdir -p "$data_dir/www"
            cp -a "$item/." "$data_dir/www/"
        elif [ "$name" = "luasrc" ]; then
            mkdir -p "$data_dir/usr/lib/lua/luci"
            cp -a "$item/." "$data_dir/usr/lib/lua/luci/"
        elif [ -d "$item" ]; then
            cp -a "$item" "$data_dir/"
        fi
    done
    
    echo "    📂 文件:"
    find "$data_dir" -type f | head -15 | sed "s|$data_dir||"
    
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
        gen_luci_scripts "$ctrl_dir" "$fmt"
        do_pack "$pkg_file" "$data_dir" "$ctrl_dir" "$fmt"
    done
    
    rm -rf "$data_dir" "$ctrl_dir"
    
    # 编译语言包（独立 ipk/apk）
    if [ -d "$LUCI_DIR/po" ]; then
        echo "  🌐 语言包:"
        local lmo_dir="$TEMP_DIR/lmo_$$"
        mkdir -p "$lmo_dir"
        
        while read -r po; do
            [ -f "$po" ] || continue
            dir_name=$(basename "$(dirname "$po")")
            file_name=$(basename "$po" .po)
            
            [ "$dir_name" = "templates" ] && continue
            
            if [ "$dir_name" = "po" ]; then
                lang="${file_name##*.}"
                base="${file_name%.*}"
            else
                lang="$dir_name"
                base="$file_name"
            fi
            
            lmo="$lmo_dir/${base}.${lang}.lmo"
            if po2lmo "$po" "$lmo" 2>/dev/null; then
                build_i18n "$luci_name" "$lang" "$lmo"
            fi
        done < <(find "$LUCI_DIR/po" -name "*.po" -type f)
        
        rm -rf "$lmo_dir"
    fi
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
