#!/bin/bash
set -e

PROJ_NAME="$1" VERSION="${2#v}" SOURCE_REPO="$3" FEEDS_DIR="$4" UPX="${5:-true}"
ARCH_PKG_DIR="$FEEDS_DIR/$PROJ_NAME"
LUCI_APP_DIR="$FEEDS_DIR/luci-app-$PROJ_NAME"

echo "📌 $PROJ_NAME v$VERSION (UPX: $UPX)"

detect_type() {
    gh api "repos/$1/contents/go.mod" &>/dev/null && echo "go" && return
    gh api "repos/$1/contents/Cargo.toml" &>/dev/null && echo "rust" && return
    echo "go"
}

fix_paths() {
    [ -d "$1" ] || return 0
    find "$1" -type f \( -name "*.sh" -o -name "*.lua" -o -name "*.js" -o -name "*.json" -o -name "*.conf" -o -name "*init*" -o -name "Makefile" \) 2>/dev/null | \
        xargs -r sed -i "s|/etc/$PROJ_NAME|/etc/config/${PROJ_NAME}_data|g" 2>/dev/null || true
}

extract_block() { sed -n "/^define Package\/.*\/$1/,/^endef/p" "$2" 2>/dev/null | grep -v "^define\|^endef" || true; }

is_download_binary() { grep -qE 'releases/download|PKG_SOURCE.*\$\(ARCH' "$1" 2>/dev/null; }

gen_makefile() {
    local type="$1" name="$2" ver="$3" repo="$4" install="$5" conffiles="$6"
    local pkg_type="Go" build_dep="golang/host" go_pkg="GO_PKG:=github.com/$repo" arch_dep="\$(GO_ARCH_DEPENDS)" upx_path="\$(GO_PKG_BUILD_BIN_DIR)/*"
    
    [ "$type" = "rust" ] && pkg_type="Rust" && build_dep="rust/host" && go_pkg="" && arch_dep="\$(RUST_ARCH_DEPENDS)" && upx_path="\$(PKG_INSTALL_DIR)/bin/*"
    
    cat << EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$name
PKG_VERSION:=$ver
PKG_RELEASE:=1
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/$repo.git
PKG_SOURCE_VERSION:=v\$(PKG_VERSION)
PKG_MIRROR_HASH:=skip
PKG_BUILD_DEPENDS:=$build_dep
PKG_BUILD_PARALLEL:=1

$go_pkg

include \$(INCLUDE_DIR)/package.mk
include \$(TOPDIR)/feeds/packages/lang/$type/$type-package.mk

define Package/\$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=$name
  DEPENDS:=$arch_dep
endef

define Package/\$(PKG_NAME)/conffiles
$conffiles
endef
$([ "$UPX" = "true" ] && echo "
define Build/Compile
	\$(call ${pkg_type}Package/Build/Compile)
	upx --best --lzma $upx_path 2>/dev/null || true
endef")

define Package/\$(PKG_NAME)/install
$install
endef

\$(eval \$(call ${pkg_type}BinPackage,\$(PKG_NAME)))
\$(eval \$(call BuildPackage,\$(PKG_NAME)))
EOF
}

main() {
    fix_paths "$LUCI_APP_DIR"
    fix_paths "$ARCH_PKG_DIR"
    
    local proj_type=$(detect_type "$SOURCE_REPO")
    echo "  📌 类型: $proj_type"
    
    local makefile="$ARCH_PKG_DIR/Makefile"
    local install="" conffiles=""
    
    [ -f "$makefile" ] && install=$(extract_block "install" "$makefile") && conffiles=$(extract_block "conffiles" "$makefile")
    
    [ -z "$conffiles" ] && conffiles="/etc/config/$PROJ_NAME
/etc/config/${PROJ_NAME}_data"
    
    if [ -z "$install" ]; then
        local bin_path="\$(GO_PKG_BUILD_BIN_DIR)/$PROJ_NAME"
        [ "$proj_type" = "rust" ] && bin_path="\$(PKG_INSTALL_DIR)/bin/$PROJ_NAME"
        install="	\$(INSTALL_DIR) \$(1)/usr/bin
	\$(INSTALL_BIN) $bin_path \$(1)/usr/bin/$PROJ_NAME"
    fi
    
    if [ ! -f "$makefile" ] || is_download_binary "$makefile"; then
        echo "  🔄 生成源码编译 Makefile"
        mkdir -p "$ARCH_PKG_DIR"
        gen_makefile "$proj_type" "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$makefile"
    else
        echo "  ✅ 保留原 Makefile"
    fi
    
    echo ""
    echo "========== Makefile ($PROJ_NAME) =========="
    cat "$makefile"
    echo "============================================"
}

main
