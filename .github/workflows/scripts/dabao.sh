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

# 查找目录并确定项目名
LUCI_APP_DIR="" ARCH_PKG_DIR="" PROJ_NAME=""
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

# 从 Makefile 提取变量值
get_makefile_var() {
    local file="$1" var="$2"
    grep -E "^${var}\s*:?=" "$file" 2>/dev/null | head -1 | sed 's/.*:*=\s*//' | tr -d ' '
}

# 从 Makefile 提取二进制名（支持多种格式）
get_bin_name() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    
    local content=$(tr '\t' ' ' < "$makefile")
    
    # 方式1: $(INSTALL_BIN) $(PKG_BUILD_DIR)/xxx
    local name=$(echo "$content" | grep -oP '\$\(INSTALL_BIN\)\s+\$\(PKG_BUILD_DIR\)/\K[^[:space:]]+' | head -1)
    [ -n "$name" ] && { echo "$name"; return; }
    
    # 方式2: $(INSTALL_BIN) $(PKG_INSTALL_DIR)/.../xxx $(1)/path/yyy - 取目标名
    name=$(echo "$content" | grep -oP '\$\(INSTALL_BIN\)\s+\$\(PKG_INSTALL_DIR\)/[^[:space:]]+\s+\$\(1\)/[^[:space:]]*/\K[^[:space:]]+' | head -1)
    [ -n "$name" ] && { echo "$name"; return; }
    
    # 方式3: $(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/xxx
    name=$(echo "$content" | grep -oP '\$\(INSTALL_BIN\)\s+\$\(GO_PKG_BUILD_BIN_DIR\)/\K[^[:space:]]+' | head -1)
    [ -n "$name" ] && { echo "$name"; return; }
    
    # 方式4: GoPackage
    if grep -qE 'GoPackage|GoBinPackage' "$makefile"; then
        name=$(get_makefile_var "$makefile" "GO_PKG_BASENAME")
        [ -z "$name" ] && name=$(get_makefile_var "$makefile" "PKG_NAME")
        [ -n "$name" ] && { echo "$name"; return; }
    fi
}

# 从 Makefile 提取二进制安装路径
get_bin_dst() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    local content=$(tr '\t' ' ' < "$makefile")
    local dst=$(echo "$content" | grep -oP '\$\(INSTALL_BIN\)\s+\$\(PKG_INSTALL_DIR\)/[^[:space:]]+\s+\$\(1\)\K/[^[:space:]]+' | head -1)
    [ -n "$dst" ] && { echo "$dst"; return; }
    dst=$(echo "$content" | grep -oP '\$\(INSTALL_BIN\)\s+\$\(GO_PKG_BUILD_BIN_DIR\)/[^[:space:]]+\s+\$\(1\)\K/[^[:space:]]+' | head -1)
    [ -n "$dst" ] && { echo "$dst"; return; }
    # GoPackage 默认
    if grep -qE 'GoPackage|GoBinPackage' "$makefile"; then
        local name=$(get_bin_name "$makefile")
        [ -n "$name" ] && echo "/usr/bin/$name"
    fi
}

get_luci_version() {
    [ -f "$LUCI_APP_DIR/Makefile" ] && grep -E "^PKG_VERSION\s*:?=" "$LUCI_APP_DIR/Makefile" | head -1 | sed 's/.*:*=\s*//' | tr -d ' '
}

fix_data_path() {
    [ -z "$PROJ_NAME" ] || [ -z "$LUCI_SRC" ] && return
    find "$LUCI_SRC" -type f \( -name "*.sh" -o -name "*init*" -o -name "*.conf" -o -name "*.config" -o -name "Makefile" -o -name "*.lua" -o -name "*.js" -o -name "*.htm" -o -name "*.json" \) 2>/dev/null | \
        xargs -r sed -i "s|/etc/$PROJ_NAME|/etc/config/${PROJ_NAME}_data|g" 2>/dev/null || true
}

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

# 解析 Makefile install
parse_install() {
    local makefile="$1" data="$2" pkg_dir="$3"
    # 合并续行，Tab转空格
    local content=$(sed ':a;N;$!ba;s/\\\n//g' "$makefile" | tr '\t' ' ')
    local in_block=false
    local found=false
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ define[[:space:]]+Package/.*/install ]] && { in_block=true; continue; }
        [[ "$line" =~ ^[[:space:]]*endef ]] && { in_block=false; continue; }
        [ "$in_block" = "false" ] && continue
        
        # 去除行首空白
        line="${line#"${line%%[![:space:]]*}"}"
        
        # INSTALL_DIR - 支持多个目录
        if [[ "$line" =~ \$\(INSTALL_DIR\) ]]; then
            local tmp="$line"
            while [[ "$tmp" =~ \$\(1\)(/[^[:space:]]+) ]]; do
                mkdir -p "$data${BASH_REMATCH[1]}"
                tmp="${tmp#*"${BASH_REMATCH[0]}"}"
            done
        fi
        
        # INSTALL_BIN（非编译目录的文件）
        if [[ "$line" =~ \$\(INSTALL_BIN\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]*) ]]; then
            local src="${BASH_REMATCH[1]}" dst="${BASH_REMATCH[2]}"
            # 排除编译目录
            if [[ ! "$src" =~ \$\(PKG_BUILD_DIR\) ]] && [[ ! "$src" =~ \$\(GO_PKG ]] && [[ ! "$src" =~ \$\(PKG_INSTALL_DIR\) ]]; then
                # 清理源路径前缀
                src="${src#\$\(CURDIR\)/}"
                src="${src#\./}"
                # 目标以/结尾时追加文件名
                [[ "$dst" == */ ]] && dst="${dst}$(basename "$src")"
                
                mkdir -p "$data$(dirname "$dst")"
                if [ -f "$pkg_dir/$src" ]; then
                    cp "$pkg_dir/$src" "$data$dst"
                    chmod 755 "$data$dst"
                    echo "    ✅ $src → $dst"
                    found=true
                fi
            fi
        fi
        
        # INSTALL_CONF / INSTALL_DATA
        if [[ "$line" =~ \$\(INSTALL_(CONF|DATA)\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]*) ]]; then
            local src="${BASH_REMATCH[2]}" dst="${BASH_REMATCH[3]}"
            # 清理源路径前缀
            src="${src#\$\(CURDIR\)/}"
            src="${src#\./}"
            # 目标以/结尾时追加文件名
            [[ "$dst" == */ ]] && dst="${dst}$(basename "$src")"
            
            mkdir -p "$data$(dirname "$dst")"
            if [ -f "$pkg_dir/$src" ]; then
                cp "$pkg_dir/$src" "$data$dst"
                chmod 644 "$data$dst"
                echo "    ✅ $src → $dst"
                found=true
            fi
        fi
        
        # CP
        if [[ "$line" =~ \$\(CP\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]*) ]]; then
            local src="${BASH_REMATCH[1]}" dst="${BASH_REMATCH[2]}"
            src="${src#\$\(CURDIR\)/}"
            src="${src#\./}"
            [[ "$dst" == */ ]] && dst="${dst}$(basename "$src")"
            
            mkdir -p "$data$(dirname "$dst")"
            [ -e "$pkg_dir/$src" ] && cp -a "$pkg_dir/$src" "$data$dst" && echo "    ✅ $src → $dst" && found=true
        fi
        
        # LN
        if [[ "$line" =~ \$\(LN\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            local target="${BASH_REMATCH[1]}" link="${BASH_REMATCH[2]}"
            mkdir -p "$data$(dirname "$link")"
            ln -sf "$target" "$data$link" && echo "    🔗 $target → $link" && found=true
        fi
    done <<< "$content"
    
    # Fallback: 扫描 files 目录
    if [ "$found" = "false" ] && [ -d "$pkg_dir/files" ]; then
        echo "    ⚠️ Makefile 解析失败，扫描 files/ 目录"
        for f in "$pkg_dir/files/"*; do
            [ -f "$f" ] || continue
            local name=$(basename "$f")
            case "$name" in
                *.init)
                    mkdir -p "$data/etc/init.d"
                    cp "$f" "$data/etc/init.d/${name%.init}"
                    chmod 755 "$data/etc/init.d/${name%.init}"
                    echo "    ✅ $name → /etc/init.d/${name%.init}"
                    ;;
                *.config)
                    mkdir -p "$data/etc/config"
                    cp "$f" "$data/etc/config/${name%.config}"
                    echo "    ✅ $name → /etc/config/${name%.config}"
                    ;;
                *.conf)
                    mkdir -p "$data/etc/config"
                    cp "$f" "$data/etc/config/${name%.conf}"
                    echo "    ✅ $name → /etc/config/${name%.conf}"
                    ;;
                *.db|*.json|*.yaml|*.yml)
                    mkdir -p "$data/etc/$PROJ_NAME"
                    cp "$f" "$data/etc/$PROJ_NAME/$name"
                    echo "    ✅ $name → /etc/$PROJ_NAME/$name"
                    ;;
                *)
                    mkdir -p "$data/etc"
                    cp "$f" "$data/etc/$name"
                    echo "    ✅ $name → /etc/$name"
                    ;;
            esac
        done
    fi
}

build_arch_pkg() {
    [ -d "$ARCH_PKG_DIR" ] && [ -f "$ARCH_PKG_DIR/Makefile" ] || return 0
    
    local base_data="$TEMP_DIR/arch_base_$$"
    rm -rf "$base_data" && mkdir -p "$base_data"
    
    echo "  🔧 架构包: $PROJ_NAME"
    echo "  📂 解析 Makefile:"
    
    # 调试：打印Makefile install块
    echo "  --- Makefile install 块 ---"
    sed -n '/define Package.*\/install/,/^endef/p' "$ARCH_PKG_DIR/Makefile" | head -20
    echo "  ----------------------------"
    
    parse_install "$ARCH_PKG_DIR/Makefile" "$base_data" "$ARCH_PKG_DIR"
    
    # 合并 luci-app 的 init.d 和 config
    [ -d "$LUCI_APP_DIR/root/etc/init.d" ] && mkdir -p "$base_data/etc/init.d" && cp -a "$LUCI_APP_DIR/root/etc/init.d/"* "$base_data/etc/init.d/" 2>/dev/null || true
    [ -d "$LUCI_APP_DIR/root/etc/config" ] && mkdir -p "$base_data/etc/config" && cp -a "$LUCI_APP_DIR/root/etc/config/"* "$base_data/etc/config/" 2>/dev/null || true
    
    local bin_dst=$(get_bin_dst "$ARCH_PKG_DIR/Makefile")
    [ -z "$bin_dst" ] && bin_dst="/usr/bin/$PROJ_NAME"
    local bin_name=$(get_bin_name "$ARCH_PKG_DIR/Makefile")
    [ -z "$bin_name" ] && bin_name="$PROJ_NAME"
    local init_name=$(find "$base_data/etc/init.d" -type f 2>/dev/null | head -1 | xargs -r basename)
    
    echo "  📌 二进制名: $bin_name → $bin_dst"
    echo "  📌 init脚本: ${init_name:-无}"
    echo "  📂 base_data 内容:"
    find "$base_data" -type f 2>/dev/null | sed 's|.*/arch_base_[0-9_]*/|    |' | head -20
    
    for arch_dir in "$BIN_DIR"/*/; do
        [ -d "$arch_dir" ] || continue
        
        local bin=$(find "$arch_dir" -name "$bin_name" -type f 2>/dev/null | head -1)
        [ -z "$bin" ] && bin=$(find "$arch_dir" -name "$PROJ_NAME" -type f 2>/dev/null | head -1)
        [ -z "$bin" ] && bin=$(find "$arch_dir" -type f -executable 2>/dev/null | head -1)
        [ -z "$bin" ] && continue
        
        local arch_name=$(basename "$arch_dir")
        local data="$TEMP_DIR/arch_${arch_name}_$$"
        local ctrl="$TEMP_DIR/arch_ctrl_$$"
        
        cp -a "$base_data" "$data"
        rm -rf "$ctrl" && mkdir -p "$ctrl" "$data$(dirname "$bin_dst")"
        do_upx "$bin"
        cp "$bin" "$data$bin_dst" && chmod 755 "$data$bin_dst"
        fix_perms "$data"
        
        [ -d "$data/etc/config" ] && find "$data/etc/config" -type f 2>/dev/null | sed "s|^$data||" > "$ctrl/conffiles"
        [ -s "$ctrl/conffiles" ] || rm -f "$ctrl/conffiles"
        
        write_control "$ctrl" "$PROJ_NAME" "$PKG_VERSION" "libc${PKG_DEPS:+, $PKG_DEPS}" "$PROJ_NAME" "$data"
        
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

build_luci() {
    [ -d "$LUCI_APP_DIR" ] || return 0
    
    local luci_name=$(basename "$LUCI_APP_DIR")
    local luci_base="${luci_name#luci-app-}"
    local luci_ver=$(get_luci_version); [ -z "$luci_ver" ] && luci_ver="$PKG_VERSION"
    local data="$TEMP_DIR/luci_data_$$" ctrl="$TEMP_DIR/luci_ctrl_$$"
    
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
    
    write_control "$ctrl" "$luci_name" "$luci_ver" "$PROJ_NAME, luci-base${LUCI_DEPS:+, $LUCI_DEPS}" "LuCI support for $PROJ_NAME" "$data"
    
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
        cp "$bin" "$data/usr/bin/$PKG_NAME" && chmod 755 "$data/usr/bin/$PKG_NAME"
        
        write_control "$ctrl" "$PKG_NAME" "$PKG_VERSION" "libc${PKG_DEPS:+, $PKG_DEPS}" "$PKG_NAME" "$data"
        
        for fmt in ipk apk; do do_pack "${arch_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"; done
        rm -rf "$data" "$ctrl"
    done
}

echo "📦 打包: $PKG_NAME v$PKG_VERSION"
[ -d "$LUCI_SRC" ] && fix_data_path
build_arch_pkg
build_luci
pack_simple_bin
echo "📁 输出:"; ls -la "$OUT_DIR/"
