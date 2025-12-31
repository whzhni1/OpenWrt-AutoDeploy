#!/bin/bash
# dabao.sh - OpenWrt 二进制 IPK/APK 打包

set -e

PKG_NAME="$1"
PKG_VERSION="${2#v}"
BIN_DIR="$3"
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
    find "$data_dir" -type f -exec chmod 644 {} \;
    find "$data_dir" -type f -path "*/bin/*" -exec chmod 755 {} \;
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
echo "📦 打包: $PKG_NAME v$PKG_VERSION"
count=0
if [ -d "$BIN_DIR" ]; then
    for bin in "$BIN_DIR"/*; do
        [ -f "$bin" ] && { pack_bin "$bin"; ((count++)) || true; }
    done
fi
echo "📊 二进制包: $count 个"
echo "📁 输出:"
ls -la "$OUT_DIR/"
