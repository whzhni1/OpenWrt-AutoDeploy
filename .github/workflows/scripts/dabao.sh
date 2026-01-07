#!/bin/bash
# dabao.sh - OpenWrt IPK/APK 打包脚本

set -e

PKG_NAME="$1"
PKG_VERSION="${2#v}"
BIN_DIR="$3"
LUCI_SRC="$4"
OUT_DIR="$(pwd)/output"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$OUT_DIR"

# ========== Makefile 解析 ==========

LUCI_APP_DIR="" ARCH_PKG_DIR="" PROJ_NAME="" PKG_DEPS=""
if [ -d "$LUCI_SRC" ]; then
    LUCI_APP_DIR=$(find "$LUCI_SRC" -maxdepth 1 -type d -name "luci-app-*" | head -1)
    if [ -n "$LUCI_APP_DIR" ]; then
        PROJ_NAME="${LUCI_APP_DIR##*luci-app-}"
        [ -d "$LUCI_SRC/$PROJ_NAME" ] && [ -f "$LUCI_SRC/$PROJ_NAME/Makefile" ] && ARCH_PKG_DIR="$LUCI_SRC/$PROJ_NAME"
    fi
fi
[ -z "$PROJ_NAME" ] && PROJ_NAME="$PKG_NAME"

echo "$PROJ_NAME" > "$OUT_DIR/.proj_name"
echo "📌 项目名: $PROJ_NAME"

# 从 Makefile 提取依赖
get_deps() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    grep -E '^\s*DEPENDS\s*:?=' "$makefile" | grep -oE '\+[a-zA-Z0-9_-]+' | sed 's/^+//' | sort -u | tr '\n' ' '
}

# 从 Makefile 提取二进制安装路径
get_bin_dst() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    tr '\t' ' ' < "$makefile" | grep -E 'INSTALL_BIN.*\$\((PKG_INSTALL_DIR|GO_PKG_BUILD_BIN_DIR|PKG_BUILD_DIR)\)' | \
        grep -oP '\$\(1\)\K/[^[:space:]]+' | head -1
}

# 从 Makefile 提取 LuCI 版本
get_luci_version() {
    [ -f "$LUCI_APP_DIR/Makefile" ] || return
    grep -E "^PKG_VERSION\s*:?=" "$LUCI_APP_DIR/Makefile" | head -1 | sed 's/.*:*=\s*//' | tr -d ' '
}

# 提取架构包依赖
if [ -f "$ARCH_PKG_DIR/Makefile" ]; then
    PKG_DEPS=$(get_deps "$ARCH_PKG_DIR/Makefile")
    [ -n "$PKG_DEPS" ] && echo "📦 依赖: $PKG_DEPS"
fi

# ========== 工具函数 ==========

do_upx() { [ "$PKG_UPX" = "true" ] && upx --best --lzma "$1" 2>/dev/null || true; }

fix_perms() {
    find "$1" -type f -exec chmod 644 {} \;
    find "$1" -type f -path "*/bin/*" -exec chmod 755 {} \;
    find "$1" -type f -path "*/sbin/*" -exec chmod 755 {} \;
    find "$1" -type f -path "*/init.d/*" -exec chmod 755 {} \;
}

do_pack() {
    local pkg_file="$1" data="$2" ctrl="$3" fmt="$4" pkg="$TEMP_DIR/pkg_$$"
    mkdir -p "$pkg"
    echo "2.0" > "$pkg/debian-binary"
    (cd "$ctrl" && tar --owner=root --group=root -czf "$pkg/control.tar.gz" ./)
    (cd "$data" && tar --owner=root --group=root -czf "$pkg/data.tar.gz" ./)
    (cd "$pkg" && tar --owner=root --group=root -czf "$OUT_DIR/${pkg_file}.$fmt" debian-binary control.tar.gz data.tar.gz)
    rm -rf "$pkg"
    echo "  📦 ${pkg_file}.$fmt"
}

write_control() {
    local ctrl_dir="$1" pkg="$2" ver="$3" deps="$4" desc="$5" data_dir="$6"
    local size=0; [ -d "$data_dir" ] && size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $pkg
Version: $ver
Architecture: all
Installed-Size: $size
Depends: $deps
Description: $desc
EOF
}

# ========== files 目录处理 ==========

declare -A INSTALL_PERMS=([INSTALL_BIN]=755 [INSTALL_SBIN]=755 [INSTALL_CONF]=644 [INSTALL_DATA]=644 [CP]=644)

parse_files() {
    local makefile="$1" data="$2" files_dir="$3"
    
    if [ ! -d "$files_dir" ]; then
        echo "    ⚠️ files 目录不存在: $files_dir"
        return 0
    fi
    
    local mf_content=""
    [ -f "$makefile" ] && mf_content=$(sed ':a;N;$!ba;s/\\\n//g' "$makefile" | tr '\t' ' ')
    
    echo "  📂 处理 files/:"
    
    for f in "$files_dir"/*; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        local src_size=$(stat -c%s "$f" 2>/dev/null || echo "0")
        
        # 在 Makefile 中查找该文件
        local line=$(echo "$mf_content" | grep -E "(^|[^a-zA-Z0-9_])${name}([^a-zA-Z0-9_]|$).*\\\$\(1\)" | head -1)
        
        if [ -n "$line" ]; then
            local dst=$(echo "$line" | grep -oP '\$\(1\)\K/[^[:space:]]+')
            [[ "$dst" == */ ]] && dst="${dst}${name}"
            
            local perm=644
            for cmd in "${!INSTALL_PERMS[@]}"; do
                [[ "$line" =~ $cmd ]] && { perm=${INSTALL_PERMS[$cmd]}; break; }
            done
            
            mkdir -p "$data$(dirname "$dst")"
            cat "$f" > "$data$dst"  # 用 cat 替代 cp
            chmod $perm "$data$dst"
            echo "    ✅ $name → $dst ($perm, ${src_size}B)"
        else
            # Fallback
            case "$name" in
                *.init)
                    mkdir -p "$data/etc/init.d"
                    cat "$f" > "$data/etc/init.d/${name%.init}"
                    chmod 755 "$data/etc/init.d/${name%.init}"
                    echo "    ✅ $name → /etc/init.d/${name%.init} (755)"
                    ;;
                *.config)
                    mkdir -p "$data/etc/config"
                    cat "$f" > "$data/etc/config/${name%.config}"
                    echo "    ✅ $name → /etc/config/${name%.config} (644)"
                    ;;
                *.conf)
                    mkdir -p "$data/etc/config"
                    cat "$f" > "$data/etc/config/${name%.conf}"
                    echo "    ✅ $name → /etc/config/${name%.conf} (644)"
                    ;;
                *.db|*.json|*.yaml|*.yml)
                    mkdir -p "$data/etc/$PROJ_NAME"
                    cat "$f" > "$data/etc/$PROJ_NAME/$name"
                    echo "    ✅ $name → /etc/$PROJ_NAME/$name (644)"
                    ;;
                *)
                    mkdir -p "$data/etc"
                    cat "$f" > "$data/etc/$name"
                    echo "    ✅ $name → /etc/$name (644)"
                    ;;
            esac
        fi
    done
}

# ========== 架构包打包 ==========

build_arch_pkg() {
    [ -d "$ARCH_PKG_DIR" ] && [ -f "$ARCH_PKG_DIR/Makefile" ] || return 0
    
    local base_data="$TEMP_DIR/arch_base_$$"
    rm -rf "$base_data" && mkdir -p "$base_data"
    
    echo "  🔧 架构包: $PROJ_NAME"
    echo "  📂 ARCH_PKG_DIR: $ARCH_PKG_DIR"
    
    parse_files "$ARCH_PKG_DIR/Makefile" "$base_data" "$ARCH_PKG_DIR/files"
    
    # 合并 luci-app 的 init.d 和 config
    if [ -d "$LUCI_APP_DIR/root/etc/init.d" ]; then
        mkdir -p "$base_data/etc/init.d"
        for f in "$LUCI_APP_DIR/root/etc/init.d"/*; do
            [ -f "$f" ] && cat "$f" > "$base_data/etc/init.d/$(basename "$f")"
        done
    fi
    if [ -d "$LUCI_APP_DIR/root/etc/config" ]; then
        mkdir -p "$base_data/etc/config"
        for f in "$LUCI_APP_DIR/root/etc/config"/*; do
            [ -f "$f" ] && cat "$f" > "$base_data/etc/config/$(basename "$f")"
        done
    fi
    
    local bin_dst=$(get_bin_dst "$ARCH_PKG_DIR/Makefile")
    [ -z "$bin_dst" ] && bin_dst="/usr/bin/$PROJ_NAME"
    local bin_name=$(basename "$bin_dst")
    local init_name=$(find "$base_data/etc/init.d" -type f 2>/dev/null | head -1 | xargs -r basename)
    
    echo "  📌 二进制: $bin_name → $bin_dst"
    echo "  📌 init: ${init_name:-无}"
    echo "  📂 base_data 内容:"
    find "$base_data" -type f -exec ls -la {} \; 2>/dev/null | head -20
    
    local deps="libc${PKG_DEPS:+, $PKG_DEPS}"
    
    for arch_dir in "$BIN_DIR"/*/; do
        [ -d "$arch_dir" ] || continue
        
        local bin=$(find "$arch_dir" -name "$bin_name" -type f 2>/dev/null | head -1)
        [ -z "$bin" ] && bin=$(find "$arch_dir" -name "$PROJ_NAME" -type f 2>/dev/null | head -1)
        [ -z "$bin" ] && bin=$(find "$arch_dir" -type f -executable 2>/dev/null | head -1)
        [ -z "$bin" ] && continue
        
        local arch_name=$(basename "$arch_dir")
        local data="$TEMP_DIR/arch_${arch_name}_$$"
        local ctrl="$TEMP_DIR/arch_ctrl_$$"
        
        rm -rf "$data" "$ctrl"
        cp -a "$base_data" "$data"
        mkdir -p "$ctrl" "$data$(dirname "$bin_dst")"
        
        do_upx "$bin"
        cat "$bin" > "$data$bin_dst"
        chmod 755 "$data$bin_dst"
        fix_perms "$data"
        
        [ -d "$data/etc/config" ] && find "$data/etc/config" -type f 2>/dev/null | sed "s|^$data||" > "$ctrl/conffiles"
        [ -s "$ctrl/conffiles" ] || rm -f "$ctrl/conffiles"
        
        write_control "$ctrl" "$PROJ_NAME" "$PKG_VERSION" "$deps" "$PROJ_NAME" "$data"
        
        for fmt in ipk apk; do
            local post="postinst" pre="prerm" postrm="postrm"
            [ "$fmt" = "apk" ] && post=".post-install" pre=".pre-deinstall" postrm=".post-deinstall"
            
            cat > "$ctrl/$post" << EOF
#!/bin/sh
[ -f "/etc/config/$PROJ_NAME" ] || touch /etc/config/$PROJ_NAME
rm -f /tmp/luci-indexcache.* 2>/dev/null; rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
${init_name:+[ -x "/etc/init.d/$init_name" ] && /etc/init.d/$init_name enable 2>/dev/null}
${init_name:+[ -x "/etc/init.d/$init_name" ] && /etc/init.d/$init_name restart 2>/dev/null}
exit 0
EOF
            cat > "$ctrl/$pre" << EOF
#!/bin/sh
${init_name:+[ -x "/etc/init.d/$init_name" ] && /etc/init.d/$init_name disable 2>/dev/null}
${init_name:+[ -x "/etc/init.d/$init_name" ] && /etc/init.d/$init_name stop 2>/dev/null}
exit 0
EOF
            cat > "$ctrl/$postrm" << EOF
#!/bin/sh
rm -f /etc/config/$PROJ_NAME; rm -rf /etc/config/${PROJ_NAME}_data
opkg remove luci-app-$PROJ_NAME luci-i18n-${PROJ_NAME}-* 2>/dev/null || true
exit 0
EOF
            chmod 755 "$ctrl/$post" "$ctrl/$pre" "$ctrl/$postrm"
            do_pack "${arch_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"
        done
        rm -rf "$data" "$ctrl"
    done
    rm -rf "$base_data"
}

# ========== LuCI 包打包 ==========

build_luci() {
    [ -d "$LUCI_APP_DIR" ] || return 0
    
    local luci_name=$(basename "$LUCI_APP_DIR")
    local luci_base="${luci_name#luci-app-}"
    local luci_ver=$(get_luci_version); [ -z "$luci_ver" ] && luci_ver="$PKG_VERSION"
    local data="$TEMP_DIR/luci_data_$$" ctrl="$TEMP_DIR/luci_ctrl_$$"
    
    local luci_deps=$(get_deps "$LUCI_APP_DIR/Makefile")
    
    echo "  🔧 LuCI: $luci_name (v$luci_ver)"
    rm -rf "$data" "$ctrl" && mkdir -p "$data" "$ctrl"
    
    if [ -d "$LUCI_APP_DIR/root" ]; then
        cp -a "$LUCI_APP_DIR/root/." "$data/"
        rm -rf "$data/etc/init.d" "$data/etc/config"
    fi
    [ -d "$LUCI_APP_DIR/htdocs" ] && mkdir -p "$data/www" && cp -a "$LUCI_APP_DIR/htdocs/." "$data/www/"
    [ -d "$LUCI_APP_DIR/luasrc" ] && mkdir -p "$data/usr/lib/lua/luci" && cp -a "$LUCI_APP_DIR/luasrc/." "$data/usr/lib/lua/luci/"
    [ -d "$LUCI_APP_DIR/ucode" ] && mkdir -p "$data/usr/share/ucode/luci" && cp -a "$LUCI_APP_DIR/ucode/." "$data/usr/share/ucode/luci/"
    
    [ -z "$(ls -A "$data" 2>/dev/null)" ] && { rm -rf "$data" "$ctrl"; return 0; }
    fix_perms "$data"
    
    local deps="$PROJ_NAME, luci-base${luci_deps:+, $luci_deps}"
    write_control "$ctrl" "$luci_name" "$luci_ver" "$deps" "LuCI support for $PROJ_NAME" "$data"
    
    for fmt in ipk apk; do
        local post="postinst"; [ "$fmt" = "apk" ] && post=".post-install"
        cat > "$ctrl/$post" << 'EOF'
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null; rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF
        chmod 755 "$ctrl/$post"
        do_pack "${luci_name}_${luci_ver}" "$data" "$ctrl" "$fmt"
    done
    rm -rf "$data" "$ctrl"
    
    [ -d "$LUCI_APP_DIR/po" ] && build_luci_i18n "$luci_name" "$luci_ver"
}

build_luci_i18n() {
    local luci_name="$1" luci_ver="$2"
    local luci_base="${luci_name#luci-app-}"
    
    for lang_dir in "$LUCI_APP_DIR/po"/*/; do
        [ -d "$lang_dir" ] || continue
        local lang=$(basename "$lang_dir"); [ "$lang" = "templates" ] && continue
        local lc="$lang"
        case "$lang" in zh_Hans) lc="zh-cn";; zh_Hant) lc="zh-tw";; pt_BR) lc="pt-br";; bn_BD) lc="bn";; nb_NO) lc="no";; esac
        
        local data="$TEMP_DIR/i18n_data_$$" ctrl="$TEMP_DIR/i18n_ctrl_$$"
        rm -rf "$data" "$ctrl" && mkdir -p "$data/usr/lib/lua/luci/i18n" "$ctrl"
        
        local has_po=false
        for po in "$lang_dir"*.po; do
            [ -f "$po" ] && po2lmo "$po" "$data/usr/lib/lua/luci/i18n/$(basename "${po%.po}").${lc}.lmo" 2>/dev/null && has_po=true
        done
        [ "$has_po" = "false" ] && { rm -rf "$data" "$ctrl"; continue; }
        
        local i18n_name="luci-i18n-${luci_base}-${lc}"
        write_control "$ctrl" "$i18n_name" "$luci_ver" "$luci_name" "Translation ($lang)" "$data"
        
        for fmt in ipk apk; do do_pack "${i18n_name}_${luci_ver}" "$data" "$ctrl" "$fmt"; done
        echo "    📦 $i18n_name"
        rm -rf "$data" "$ctrl"
    done
}

# ========== 简单二进制打包 ==========

pack_simple_bin() {
    [ -d "$ARCH_PKG_DIR" ] && return 0
    
    for arch_dir in "$BIN_DIR"/*/; do
        [ -d "$arch_dir" ] || continue
        
        local bin=$(find "$arch_dir" -name "$PKG_NAME" -type f 2>/dev/null | head -1)
        [ -z "$bin" ] && bin=$(find "$arch_dir" -type f -executable 2>/dev/null | head -1)
        [ -z "$bin" ] && continue
        
        local arch_name=$(basename "$arch_dir")
        local data="$TEMP_DIR/bin_data_$$" ctrl="$TEMP_DIR/bin_ctrl_$$"
        rm -rf "$data" "$ctrl" && mkdir -p "$data/usr/bin" "$ctrl"
        
        do_upx "$bin"
        cat "$bin" > "$data/usr/bin/$PKG_NAME"
        chmod 755 "$data/usr/bin/$PKG_NAME"
        
        write_control "$ctrl" "$PKG_NAME" "$PKG_VERSION" "libc" "$PKG_NAME" "$data"
        
        for fmt in ipk apk; do do_pack "${arch_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"; done
        rm -rf "$data" "$ctrl"
    done
}

# ========== 主逻辑 ==========

echo "📦 打包: $PKG_NAME v$PKG_VERSION"
build_arch_pkg
build_luci
pack_simple_bin
echo "📁 输出:"; ls -la "$OUT_DIR/"
