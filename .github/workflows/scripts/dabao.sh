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

# 输出项目名供工作流使用
echo "$PROJ_NAME" > "$OUT_DIR/.proj_name"
echo "📌 项目名: $PROJ_NAME"

# 从 Makefile 提取二进制名
get_bin_name() {
    [ -f "$1" ] && grep -oP '\$\(INSTALL_BIN\)\s+\$\(PKG_BUILD_DIR\)/\K[^[:space:]]+' "$1" | head -1
}

# 路径替换
fix_data_path() {
    [ -z "$PROJ_NAME" ] || [ -z "$LUCI_SRC" ] && return
    find "$LUCI_SRC" -type f \( -name "*.sh" -o -name "*init*" -o -name "*.conf" -o -name "*.config" -o -name "Makefile" -o -name "*.lua" -o -name "*.js" -o -name "*.htm" -o -name "*.json" \) 2>/dev/null | \
        xargs -r sed -i "s|/etc/$PROJ_NAME|/etc/config/${PROJ_NAME}_data|g" 2>/dev/null || true
}

# 获取 LuCI 版本
get_luci_version() {
    [ -f "$LUCI_APP_DIR/Makefile" ] && grep -E "^PKG_VERSION\s*:?=" "$LUCI_APP_DIR/Makefile" | head -1 | sed 's/.*:*=\s*//' | tr -d ' '
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

# 解析 Makefile install（尽量保留已有逻辑）
parse_install() {
    local makefile="$1" data="$2" pkg_dir="$3"
    local in_block=false

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*define[[:space:]]+Package/.*/install ]] && { in_block=true; continue; }
        [[ "$line" =~ ^endef ]] && { in_block=false; continue; }
        [ "$in_block" = "false" ] && continue

        if [[ "$line" =~ \$\(INSTALL_DIR\)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            mkdir -p "$data${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \$\(INSTALL_BIN\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            local src="${BASH_REMATCH[1]}" dst="${BASH_REMATCH[2]}"
            mkdir -p "$data$(dirname "$dst")"
            if [[ ! "$src" =~ \$\(PKG_BUILD_DIR\) ]]; then
                src="${src#./}"; [ -f "$pkg_dir/$src" ] && cp "$pkg_dir/$src" "$data$dst" && chmod 755 "$data$dst"
            fi
        elif [[ "$line" =~ \$\(INSTALL_(CONF|DATA)\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            local src="${BASH_REMATCH[2]#./}" dst="${BASH_REMATCH[3]}"
            mkdir -p "$data$(dirname "$dst")"
            [ -f "$pkg_dir/$src" ] && cp "$pkg_dir/$src" "$data$dst" && chmod 644 "$data$dst"
        elif [[ "$line" =~ \$\(CP\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            local src="${BASH_REMATCH[1]#./}" dst="${BASH_REMATCH[2]}"
            mkdir -p "$data$(dirname "$dst")"
            [ -e "$pkg_dir/$src" ] && cp -a "$pkg_dir/$src" "$data$dst"
        elif [[ "$line" =~ \$\(LN\)[[:space:]]+([^[:space:]]+)[[:space:]]+\$\(1\)(/[^[:space:]]+) ]]; then
            local target="${BASH_REMATCH[1]}" link="${BASH_REMATCH[2]}"
            mkdir -p "$data$(dirname "$link")"
            ln -sf "$target" "$data$link"
        fi
    done < "$makefile"
}

# 获取二进制安装路径
get_bin_dst() {
    [ -f "$1" ] && grep -oP '\$\(INSTALL_BIN\)\s+\$\(PKG_BUILD_DIR\)/[^[:space:]]+\s+\$\(1\)\K/[^[:space:]]+' "$1" | head -1
}

# 复用 control 文件生成
write_control() {
    local ctrl_dir="$1"; local pkg="$2"; local ver="$3"; local arch="$4"; local deps="$5"; local desc="$6"; local data_dir="$7"
    local size="0"
    [ -n "$data_dir" ] && [ -d "$data_dir" ] && size=$(du -sk "$data_dir" | cut -f1)
    cat > "$ctrl_dir/control" << EOF
Package: $pkg
Version: $ver
Architecture: $arch
Installed-Size: $size
Depends: $deps
Description: $desc
EOF
}

# 架构包
build_arch_pkg() {
    [ -d "$ARCH_PKG_DIR" ] && [ -f "$ARCH_PKG_DIR/Makefile" ] || return 0

    local base_data="$TEMP_DIR/arch_base_$$"
    rm -rf "$base_data" && mkdir -p "$base_data"

    echo "  🔧 架构包: $PROJ_NAME"

    # 先解析 Makefile 安装指令到 base_data
    parse_install "$ARCH_PKG_DIR/Makefile" "$base_data" "$ARCH_PKG_DIR"

    # 处理 ARCH_PKG_DIR/files 目录（复制 files 下的内容到 base_data）
    if [ -d "$ARCH_PKG_DIR/files" ]; then
        # 保证 files 中的相对路径直接映射到 base_data 根
        cp -a "$ARCH_PKG_DIR/files/." "$base_data/" 2>/dev/null || true
    fi

    # 合并 luci-app 的 init.d 和 config（优先使用 luci-app 的 root 文件）
    [ -d "$LUCI_APP_DIR/root/etc/init.d" ] && mkdir -p "$base_data/etc/init.d" && cp -a "$LUCI_APP_DIR/root/etc/init.d/"* "$base_data/etc/init.d/" 2>/dev/null || true
    [ -d "$LUCI_APP_DIR/root/etc/config" ] && mkdir -p "$base_data/etc/config" && cp -a "$LUCI_APP_DIR/root/etc/config/"* "$base_data/etc/config/" 2>/dev/null || true

    local bin_dst=$(get_bin_dst "$ARCH_PKG_DIR/Makefile")
    [ -z "$bin_dst" ] && bin_dst="/usr/bin/$PROJ_NAME"
    local bin_name=$(get_bin_name "$ARCH_PKG_DIR/Makefile")
    [ -z "$bin_name" ] && bin_name="$PROJ_NAME"
    local init_name=$(find "$base_data/etc/init.d" -type f 2>/dev/null | head -1 | xargs -r basename)

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

        # conffiles：列出 /etc/config 下的文件（相对路径）
        if [ -d "$data/etc/config" ]; then
            (cd "$data" && find etc/config -type f 2>/dev/null | sed "s|^|/|") > "$ctrl/conffiles" || true
        fi
        [ -s "$ctrl/conffiles" ] || rm -f "$ctrl/conffiles"

        # 生成 control 文件（架构包应使用具体架构）
        local deps="libc${PKG_DEPS:+, $PKG_DEPS}"
        write_control "$ctrl" "$PROJ_NAME" "$PKG_VERSION" "$arch_name" "$deps" "$PROJ_NAME" "$data"

        # 生成 maintainer 脚本（postinst, prerm, postrm）
        for fmt in ipk apk; do
            local post="postinst" pre="prerm" postrm="postrm"
            [ "$fmt" = "apk" ] && post=".post-install" pre=".pre-deinstall" postrm=".post-deinstall"

            # postinst：创建配置文件、刷新 luci 缓存、reload rpcd、enable/restart init
            cat > "$ctrl/$post" << EOF
#!/bin/sh
[ -f "/etc/config/$PROJ_NAME" ] || touch /etc/config/$PROJ_NAME
rm -f /tmp/luci-indexcache.* 2>/dev/null; rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
if [ -n "$init_name" ] && [ -x "/etc/init.d/$init_name" ]; then
    /etc/init.d/$init_name enable 2>/dev/null || true
    /etc/init.d/$init_name restart 2>/dev/null || true
fi
exit 0
EOF

            # prerm：disable/stop init
            cat > "$ctrl/$pre" << EOF
#!/bin/sh
if [ -n "$init_name" ] && [ -x "/etc/init.d/$init_name" ]; then
    /etc/init.d/$init_name disable 2>/dev/null || true
    /etc/init.d/$init_name stop 2>/dev/null || true
fi
exit 0
EOF

            # postrm：删除配置与 i18n/luci 相关包（尽量安全）
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

# LuCI 包
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
        # 保留 init.d 与 config 到 arch 包，不在 luci 包重复放置
        rm -rf "$data/etc/init.d" "$data/etc/config"
    fi
    [ -d "$LUCI_APP_DIR/htdocs" ] && mkdir -p "$data/www" && cp -a "$LUCI_APP_DIR/htdocs/." "$data/www/"
    [ -d "$LUCI_APP_DIR/luasrc" ] && mkdir -p "$data/usr/lib/lua/luci" && cp -a "$LUCI_APP_DIR/luasrc/." "$data/usr/lib/lua/luci/"
    [ -d "$LUCI_APP_DIR/ucode" ] && mkdir -p "$data/usr/share/ucode/luci" && cp -a "$LUCI_APP_DIR/ucode/." "$data/usr/share/ucode/luci/"

    [ -z "$(ls -A "$data" 2>/dev/null)" ] && { rm -rf "$data" "$ctrl"; return 0; }
    fix_perms "$data"

    # luci 包依赖核心包（使用 PROJ_NAME）
    local deps="$PROJ_NAME, luci-base${LUCI_DEPS:+, $LUCI_DEPS}"
    write_control "$ctrl" "$luci_name" "$luci_ver" "all" "$deps" "LuCI support for $PROJ_NAME" "$data"

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

# 语言包
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
        # 语言包依赖 luci-app 包本身（使用 luci_name）
        write_control "$ctrl" "$i18n_name" "$luci_ver" "all" "$luci_name" "Translation ($lang)" "$data"

        for fmt in ipk apk; do do_pack "${i18n_name}_${luci_ver}" "$data" "$ctrl" "$fmt"; done
        echo "    📦 $i18n_name"
        rm -rf "$data" "$ctrl"
    done
}

# 简单二进制（无架构包）
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

        local deps="libc${PKG_DEPS:+, $PKG_DEPS}"
        write_control "$ctrl" "$PKG_NAME" "$PKG_VERSION" "all" "$deps" "$PKG_NAME" "$data"

        for fmt in ipk apk; do do_pack "${arch_name}_${PKG_VERSION}" "$data" "$ctrl" "$fmt"; done
        rm -rf "$data" "$ctrl"
    done
}

# 主流程
echo "📦 打包: $PKG_NAME v$PKG_VERSION"
[ -d "$LUCI_SRC" ] && fix_data_path
build_arch_pkg
build_luci
pack_simple_bin
echo "📁 输出:"; ls -la "$OUT_DIR/"
