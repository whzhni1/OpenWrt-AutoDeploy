#!/bin/bash
# process-makefile.sh - 处理 Makefile，修改路径，生成/转换为源码编译

set -e

PROJ_NAME="$1"
VERSION="${2#v}"
SOURCE_REPO="$3"
FEEDS_DIR="$4"
UPX="${5:-true}"

ARCH_PKG_DIR="$FEEDS_DIR/$PROJ_NAME"
LUCI_APP_DIR="$FEEDS_DIR/luci-app-$PROJ_NAME"

echo "📌 处理 Makefile: $PROJ_NAME v$VERSION"
echo "📌 UPX 压缩: $UPX"

# 检测项目类型
detect_type() {
    local repo="$1"
    if gh api "repos/$repo/contents/go.mod" &>/dev/null; then
        echo "go"
    elif gh api "repos/$repo/contents/Cargo.toml" &>/dev/null; then
        echo "rust"
    else
        echo "unknown"
    fi
}

# 修改路径
fix_paths() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    echo "  🔧 修改路径: /etc/$PROJ_NAME → /etc/config/${PROJ_NAME}_data"
    find "$dir" -type f \( -name "*.sh" -o -name "*.lua" -o -name "*.js" -o -name "*.htm" -o -name "*.json" -o -name "*.conf" -o -name "*.config" -o -name "*init*" -o -name "Makefile" \) 2>/dev/null | while read -r f; do
        sed -i "s|/etc/$PROJ_NAME|/etc/config/${PROJ_NAME}_data|g" "$f" 2>/dev/null || true
    done
}

# 提取 install 块
extract_install() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    sed -n '/^define Package\/.*\/install/,/^endef/p' "$makefile" | grep -v "^define\|^endef" || true
}

# 提取 conffiles 块
extract_conffiles() {
    local makefile="$1"
    [ -f "$makefile" ] || return
    sed -n '/^define Package\/.*\/conffiles/,/^endef/p' "$makefile" | grep -v "^define\|^endef" || true
}

# 检测是否为下载二进制类型
is_download_binary() {
    local makefile="$1"
    grep -qE 'PKG_SOURCE.*\$\((ARCH|PKG_ARCH)\)|releases/download.*\$\((ARCH|PKG_ARCH|PKG_VERSION)\)' "$makefile" 2>/dev/null
}

# 生成 UPX 压缩块
gen_upx_block() {
    [ "$UPX" != "true" ] && return
    cat << 'EOF'

define Build/Compile
	$(call GoPackage/Build/Compile)
	$(if $(wildcard $(GO_PKG_BUILD_BIN_DIR)/*),upx --best --lzma $(GO_PKG_BUILD_BIN_DIR)/* || true)
endef
EOF
}

gen_upx_block_rust() {
    [ "$UPX" != "true" ] && return
    cat << 'EOF'

define Build/Compile
	$(call RustPackage/Build/Compile)
	$(if $(wildcard $(PKG_INSTALL_DIR)/bin/*),upx --best --lzma $(PKG_INSTALL_DIR)/bin/* || true)
endef
EOF
}

# 生成 Go Makefile
gen_go_makefile() {
    local name="$1" ver="$2" repo="$3" install="$4" conffiles="$5"
    
    cat << EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$name
PKG_VERSION:=$ver
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/$repo.git
PKG_SOURCE_VERSION:=v\$(PKG_VERSION)
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Auto Generated

PKG_BUILD_DEPENDS:=golang/host upx/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/$repo

include \$(INCLUDE_DIR)/package.mk
include \$(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/\$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=$name
  URL:=https://github.com/$repo
  DEPENDS:=\$(GO_ARCH_DEPENDS)
endef

define Package/\$(PKG_NAME)/conffiles
$conffiles
endef
$(gen_upx_block)

define Package/\$(PKG_NAME)/install
$install
endef

\$(eval \$(call GoBinPackage,\$(PKG_NAME)))
\$(eval \$(call BuildPackage,\$(PKG_NAME)))
EOF
}

# 生成 Rust Makefile
gen_rust_makefile() {
    local name="$1" ver="$2" repo="$3" install="$4" conffiles="$5"
    
    cat << EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$name
PKG_VERSION:=$ver
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/$repo.git
PKG_SOURCE_VERSION:=v\$(PKG_VERSION)
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Auto Generated

PKG_BUILD_DEPENDS:=rust/host upx/host
PKG_BUILD_PARALLEL:=1

include \$(INCLUDE_DIR)/package.mk
include \$(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/\$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=$name
  URL:=https://github.com/$repo
  DEPENDS:=\$(RUST_ARCH_DEPENDS)
endef

define Package/\$(PKG_NAME)/conffiles
$conffiles
endef
$(gen_upx_block_rust)

define Package/\$(PKG_NAME)/install
$install
endef

\$(eval \$(call RustBinPackage,\$(PKG_NAME)))
\$(eval \$(call BuildPackage,\$(PKG_NAME)))
EOF
}

# 默认 install 块
default_install() {
    local name="$1"
    cat << EOF
	\$(INSTALL_DIR) \$(1)/usr/bin
	\$(INSTALL_BIN) \$(GO_PKG_BUILD_BIN_DIR)/$name \$(1)/usr/bin/$name
EOF
}

# 默认 conffiles
default_conffiles() {
    local name="$1"
    cat << EOF
/etc/config/$name
/etc/config/${name}_data
EOF
}

# 添加 UPX 到现有 Makefile
add_upx_to_makefile() {
    local makefile="$1" proj_type="$2"
    
    [ "$UPX" != "true" ] && return
    
    # 检查是否已有 Build/Compile
    if grep -q "^define Build/Compile" "$makefile"; then
        # 在现有 Build/Compile 的 endef 前添加 upx
        sed -i '/^define Build\/Compile/,/^endef/{
            /^endef/i\	upx --best --lzma $(GO_PKG_BUILD_BIN_DIR)/* 2>/dev/null || true
        }' "$makefile"
    else
        # 添加新的 Build/Compile 块
        if [ "$proj_type" = "go" ]; then
            sed -i '/\$(eval.*GoBinPackage/i\
define Build/Compile\
	$(call GoPackage/Build/Compile)\
	upx --best --lzma $(GO_PKG_BUILD_BIN_DIR)/* 2>/dev/null || true\
endef\
' "$makefile"
        elif [ "$proj_type" = "rust" ]; then
            sed -i '/\$(eval.*RustBinPackage/i\
define Build/Compile\
	$(call RustPackage/Build/Compile)\
	upx --best --lzma $(PKG_INSTALL_DIR)/bin/* 2>/dev/null || true\
endef\
' "$makefile"
        fi
    fi
    
    # 添加 upx/host 到 PKG_BUILD_DEPENDS
    if ! grep -q "upx/host" "$makefile"; then
        sed -i 's/PKG_BUILD_DEPENDS:=\(.*\)/PKG_BUILD_DEPENDS:=\1 upx\/host/' "$makefile"
    fi
}

# 主处理逻辑
main() {
    fix_paths "$LUCI_APP_DIR"
    
    local proj_type=$(detect_type "$SOURCE_REPO")
    echo "  📌 项目类型: $proj_type"
    
    if [ -d "$ARCH_PKG_DIR" ] && [ -f "$ARCH_PKG_DIR/Makefile" ]; then
        local makefile="$ARCH_PKG_DIR/Makefile"
        
        fix_paths "$ARCH_PKG_DIR"
        
        local install=$(extract_install "$makefile")
        local conffiles=$(extract_conffiles "$makefile")
        
        [ -z "$conffiles" ] && conffiles=$(default_conffiles "$PROJ_NAME")
        [ -z "$install" ] && install=$(default_install "$PROJ_NAME")
        
        if is_download_binary "$makefile"; then
            echo "  🔄 转换: 下载二进制 → 源码编译"
            case "$proj_type" in
                go) gen_go_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$makefile" ;;
                rust) gen_rust_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$makefile" ;;
                *) gen_go_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$makefile" ;;
            esac
        else
            echo "  ✅ 已是源码编译"
            
            # 添加 conffiles
            if ! grep -q "define Package/.*/conffiles" "$makefile"; then
                sed -i "/^define Package\/$PROJ_NAME$/,/^endef/{
                    /^endef/a\\
\\
define Package/$PROJ_NAME/conffiles\\
$conffiles\\
endef
                }" "$makefile"
            fi
            
            # 添加 UPX
            add_upx_to_makefile "$makefile" "$proj_type"
        fi
    else
        echo "  📝 生成最小 Makefile"
        mkdir -p "$ARCH_PKG_DIR"
        
        local install=$(default_install "$PROJ_NAME")
        local conffiles=$(default_conffiles "$PROJ_NAME")
        
        case "$proj_type" in
            go) gen_go_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$ARCH_PKG_DIR/Makefile" ;;
            rust) gen_rust_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$ARCH_PKG_DIR/Makefile" ;;
            *) gen_go_makefile "$PROJ_NAME" "$VERSION" "$SOURCE_REPO" "$install" "$conffiles" > "$ARCH_PKG_DIR/Makefile" ;;
        esac
    fi
    
    echo ""
    echo "========== 架构包 Makefile ($PROJ_NAME) =========="
    cat "$ARCH_PKG_DIR/Makefile"
    echo "==================================================="
    
    if [ -f "$LUCI_APP_DIR/Makefile" ]; then
        echo ""
        echo "========== LuCI Makefile =========="
        cat "$LUCI_APP_DIR/Makefile"
        echo "===================================="
    fi
}

main
