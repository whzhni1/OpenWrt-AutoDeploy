#!/bin/bash
set -e

PROJ_NAME="$1" VERSION="${2#v}" SOURCE_REPO="$3" FEEDS_DIR="$4" UPX="${5:-true}"
ARCH_PKG_DIR="$FEEDS_DIR/$PROJ_NAME"
LUCI_APP_DIR="$FEEDS_DIR/luci-app-$PROJ_NAME"
MAKEFILE="$ARCH_PKG_DIR/Makefile"

# 检测项目类型
detect_type() {
    gh api "repos/$1/contents/go.mod" &>/dev/null && echo "go|go.mod 存在" && return
    gh api "repos/$1/contents/Cargo.toml" &>/dev/null && echo "rust|Cargo.toml 存在" && return
    echo "go|默认 (未检测到特征)"
}

# 检测 Makefile 类型
detect_makefile() {
    [ ! -f "$1" ] && echo "none|不存在" && return
    grep -qE 'PKG_SOURCE_PROTO:=git|GO_PKG:=|GoPackage|RustPackage|golang-package.mk|rust-package.mk' "$1" 2>/dev/null && echo "source|源码编译" && return
    grep -qE 'releases/download|wget|PKG_SOURCE.*\.(tar|zip|gz)' "$1" 2>/dev/null && echo "binary|下载二进制" && return
    echo "binary|未知类型"
}

# 提取 Makefile 块内容
extract_block() {
    [ -f "$2" ] && sed -n "/^define Package\/[^/]*\/$1/,/^endef/p" "$2" 2>/dev/null | grep -v "^define\|^endef" || true
}

# 路径替换
fix_paths() {
    [ -d "$1" ] || return 0
    local old="/etc/$PROJ_NAME" new="/etc/config/${PROJ_NAME}_data" count=0
    while IFS= read -r f; do
        grep -q "$old" "$f" 2>/dev/null && sed -i "s|$old|$new|g" "$f" && ((count++)) || true
    done < <(find "$1" -type f \( -name "*.sh" -o -name "*.lua" -o -name "*.js" -o -name "*.json" -o -name "*.conf" -o -name "*init*" -o -name "Makefile" -o -name "*.htm" \) 2>/dev/null)
    [ "$count" -gt 0 ] && echo "  📂 路径替换: $old → $new ($count 个文件)"
}

# 生成 Makefile
gen_makefile() {
    local type="$1" install="$2" conffiles="$3"
    local is_rust=false && [ "$type" = "rust" ] && is_rust=true
    local build_dep="golang/host" arch_dep="\$(GO_ARCH_DEPENDS)" bin_path="\$(GO_PKG_BUILD_BIN_DIR)/$PROJ_NAME"
    $is_rust && build_dep="rust/host" && arch_dep="\$(RUST_ARCH_DEPENDS)" && bin_path="\$(PKG_INSTALL_DIR)/bin/$PROJ_NAME"
    
    # 默认 install（含 UPX）
    if [ -z "$install" ]; then
        install="	\$(INSTALL_DIR) \$(1)/usr/bin
	\$(INSTALL_BIN) $bin_path \$(1)/usr/bin/$PROJ_NAME"
        [ "$UPX" = "true" ] && install="$install
	upx --best --lzma \$(1)/usr/bin/$PROJ_NAME 2>/dev/null || true"
    elif [ "$UPX" = "true" ]; then
        # 已有 install，追加 UPX
        install="$install
	upx --best --lzma \$(1)/usr/bin/$PROJ_NAME 2>/dev/null || true"
    fi
    
    [ -z "$conffiles" ] && conffiles="/etc/config/$PROJ_NAME
/etc/config/${PROJ_NAME}_data"

    cat << EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$PROJ_NAME
PKG_VERSION:=$VERSION
PKG_RELEASE:=1
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/$SOURCE_REPO.git
PKG_SOURCE_VERSION:=v\$(PKG_VERSION)
PKG_MIRROR_HASH:=skip
PKG_BUILD_DEPENDS:=$build_dep
PKG_BUILD_PARALLEL:=1
$($is_rust || echo "
GO_PKG:=github.com/$SOURCE_REPO")

include \$(INCLUDE_DIR)/package.mk
include \$(TOPDIR)/feeds/packages/lang/$type/$type-package.mk

define Package/\$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=$PROJ_NAME
  DEPENDS:=$arch_dep
endef

define Package/\$(PKG_NAME)/conffiles
$conffiles
endef

define Package/\$(PKG_NAME)/install
$install
endef

$($is_rust && echo "\$(eval \$(call BuildPackage,\$(PKG_NAME)))" || echo "\$(eval \$(call GoBinPackage,\$(PKG_NAME)))
\$(eval \$(call BuildPackage,\$(PKG_NAME)))")
EOF
}

# 添加 conffiles 到现有 Makefile
add_conffiles() {
    grep -q "define Package/.*/conffiles" "$1" 2>/dev/null && echo "  ⏭️ conffiles 已存在" && return
    local tmp=$(mktemp)
    awk -v name="$PROJ_NAME" '
        /^define Package\/.*\/install/ && !added {
            print "define Package/" name "/conffiles"
            print "/etc/config/" name
            print "/etc/config/" name "_data"
            print "endef\n"
            added = 1
        }
        { print }
    ' "$1" > "$tmp" && mv "$tmp" "$1"
    echo "  ✅ 已添加 conffiles"
}

# 主流程
echo -e "\n处理: $PROJ_NAME v$VERSION"
echo "  📌 项目名: $PROJ_NAME"
echo "  📌 源仓库: $SOURCE_REPO"
echo "  📌 UPX 压缩: $UPX"

type_result=$(detect_type "$SOURCE_REPO")
proj_type="${type_result%%|*}"
echo "  🔧 类型检测: ${proj_type^} (${type_result##*|})"

fix_paths "$LUCI_APP_DIR"
fix_paths "$ARCH_PKG_DIR"

mf_result=$(detect_makefile "$MAKEFILE")
mf_type="${mf_result%%|*}"

case "$mf_type" in
    none)
        echo "  📝 Makefile: ${mf_result##*|} → 生成源码编译"
        mkdir -p "$ARCH_PKG_DIR"
        gen_makefile "$proj_type" "" "" > "$MAKEFILE"
        ;;
    binary)
        echo "  📝 Makefile: ${mf_result##*|} → 转换为源码编译"
        gen_makefile "$proj_type" "$(extract_block install "$MAKEFILE")" "$(extract_block conffiles "$MAKEFILE")" > "$MAKEFILE"
        ;;
    source)
        echo "  📝 Makefile: ${mf_result##*|} → 仅添加 conffiles"
        add_conffiles "$MAKEFILE"
        ;;
esac

echo -e "\n┌─── Makefile: $PROJ_NAME ───"
cat "$MAKEFILE"
echo "└────────────────────────────────"
