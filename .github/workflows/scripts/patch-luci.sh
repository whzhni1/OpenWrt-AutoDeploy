#!/bin/bash
# 用法: ./patch-luci.sh <luci目录> <服务名> <配置文件列表>

set -e

LUCI_DIR="$1"
SERVICE_NAME="$2"
CONFFILES="$3"

[ -d "$LUCI_DIR" ] || { echo "❌ 目录不存在: $LUCI_DIR"; exit 1; }

MAKEFILE=$(find "$LUCI_DIR" -maxdepth 2 -name "Makefile" | head -1)
[ -f "$MAKEFILE" ] || { echo "❌ 未找到 Makefile"; exit 1; }

PKG_NAME=$(grep -oP 'PKG_NAME:=\K\S+' "$MAKEFILE" 2>/dev/null || basename "$LUCI_DIR")
echo "📝 补丁: $PKG_NAME (服务: $SERVICE_NAME)"

if grep -q "# AUTO_PATCH" "$MAKEFILE"; then
    echo "⏭️ 已打过补丁"
    exit 0
fi

# conffiles
CONFFILES_BLOCK=""
if [ -n "$CONFFILES" ]; then
    CONFFILES_BLOCK="
define Package/$PKG_NAME/conffiles
$(echo "$CONFFILES" | tr ' ' '\n')
endef"
fi

cat >> "$MAKEFILE" << 'PATCH_END'

# AUTO_PATCH
PATCH_END

[ -n "$CONFFILES_BLOCK" ] && echo "$CONFFILES_BLOCK" >> "$MAKEFILE"

cat >> "$MAKEFILE" << EOF

define Package/$PKG_NAME/postinst
#!/bin/sh
[ -n "\$\$IPKG_INSTROOT" ] || {
    /etc/init.d/$SERVICE_NAME enable 2>/dev/null
    /etc/init.d/$SERVICE_NAME restart 2>/dev/null
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
}
exit 0
endef

define Package/$PKG_NAME/prerm
#!/bin/sh
[ -n "\$\$IPKG_INSTROOT" ] || {
    /etc/init.d/$SERVICE_NAME disable 2>/dev/null
    /etc/init.d/$SERVICE_NAME stop 2>/dev/null
}
exit 0
endef

define Package/$PKG_NAME/postrm
#!/bin/sh
[ -n "\$\$IPKG_INSTROOT" ] || {
    rm -f /etc/config/$SERVICE_NAME
    rm -rf /etc/$SERVICE_NAME
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
}
exit 0
endef
EOF

echo "✅ 补丁完成"
