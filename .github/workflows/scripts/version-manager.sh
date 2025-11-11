#!/bin/bash

set -e

VERSION_FILE="${VERSION_FILE:-version.txt}"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 用法说明
usage() {
    cat << EOF
版本管理脚本

用法:
  $0 read <name>              读取项目版本
  $0 write <name> <version>   写入/更新项目版本
  $0 check <name>             检查项目是否存在
  $0 list                     列出所有项目

示例:
  $0 read tailscale           # 输出: v1.0.0
  $0 write tailscale v1.0.1   # 写入或更新
  $0 check tailscale          # 存在返回0，不存在返回1
  $0 list                     # 列出所有项目

环境变量:
  VERSION_FILE    版本文件路径（默认: version.txt）
EOF
    exit 1
}

# 确保文件存在
ensure_file() {
    if [ ! -f "$VERSION_FILE" ]; then
        echo -e "${YELLOW}创建版本文件: $VERSION_FILE${NC}" >&2
        touch "$VERSION_FILE"
    fi
}

# 读取版本
read_version() {
    local name="$1"
    
    if [ -z "$name" ]; then
        echo -e "${RED}错误: 项目名称不能为空${NC}" >&2
        exit 1
    fi
    
    ensure_file
    
    # 查找匹配行
    local line=$(grep "^${name}/" "$VERSION_FILE" 2>/dev/null || true)
    
    if [ -z "$line" ]; then
        echo "" # 返回空字符串表示不存在
        return 1
    fi
    
    # 提取版本号
    local version="${line#*/}"
    echo "$version"
    return 0
}

# 写入/更新版本
write_version() {
    local name="$1"
    local version="$2"
    
    if [ -z "$name" ] || [ -z "$version" ]; then
        echo -e "${RED}错误: 项目名称和版本号不能为空${NC}" >&2
        exit 1
    fi
    
    ensure_file
    
    # 检查是否已存在
    if grep -q "^${name}/" "$VERSION_FILE" 2>/dev/null; then
        # 更新现有记录
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${name}/.*|${name}/${version}|" "$VERSION_FILE"
        else
            sed -i "s|^${name}/.*|${name}/${version}|" "$VERSION_FILE"
        fi
        echo -e "${GREEN}✓${NC} 更新: ${name}/${version}" >&2
    else
        # 添加新记录
        echo "${name}/${version}" >> "$VERSION_FILE"
        echo -e "${GREEN}✓${NC} 添加: ${name}/${version}" >&2
    fi
    
    # 排序（可选）
    sort -o "$VERSION_FILE" "$VERSION_FILE"
}

# 检查是否存在
check_exists() {
    local name="$1"
    
    if [ -z "$name" ]; then
        echo -e "${RED}错误: 项目名称不能为空${NC}" >&2
        exit 1
    fi
    
    ensure_file
    
    if grep -q "^${name}/" "$VERSION_FILE" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 列出所有项目
list_all() {
    ensure_file
    
    if [ ! -s "$VERSION_FILE" ]; then
        echo -e "${YELLOW}版本文件为空${NC}" >&2
        return 0
    fi
    
    echo "项目列表:" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    while IFS='/' read -r name version; do
        printf "%-30s %s\n" "$name" "$version" >&2
    done < "$VERSION_FILE"
}

# 主逻辑
case "${1:-}" in
    read|r|R)
        read_version "$2"
        ;;
    write|w|W)
        write_version "$2" "$3"
        ;;
    check|c|C)
        check_exists "$2"
        ;;
    list|l|L)
        list_all
        ;;
    *)
        usage
        ;;
esac
