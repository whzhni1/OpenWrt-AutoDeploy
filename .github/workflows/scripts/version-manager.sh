#!/bin/bash

set -e

VERSION_FILE="${VERSION_FILE:-config/version.txt}"

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
  $0 read openlist2           # 输出: v4.1.7
  $0 write openlist2 v4.1.8   # 写入或更新
  $0 check openlist2          # 存在返回0，不存在返回1
  $0 list                     # 列出所有项目

环境变量:
  VERSION_FILE    版本文件路径（默认: config/version.txt）
EOF
    exit 1
}

# 确保文件存在
ensure_file() {
    local dir=$(dirname "$VERSION_FILE")
    
    if [ ! -d "$dir" ] && [ "$dir" != "." ]; then
        mkdir -p "$dir"
    fi
    
    if [ ! -f "$VERSION_FILE" ]; then
        echo "创建版本文件: $VERSION_FILE" >&2
        touch "$VERSION_FILE"
    fi
}

# 读取版本
read_version() {
    local name="$1"
    
    if [ -z "$name" ]; then
        echo "错误: 项目名称不能为空" >&2
        exit 1
    fi
    
    ensure_file
    
    local line=$(grep "^${name}|" "$VERSION_FILE" 2>/dev/null || true)
    
    if [ -z "$line" ]; then
        return 1
    fi
    
    echo "${line#*|}"
}

# 写入/更新版本
write_version() {
    local name="$1"
    local version="$2"
    
    if [ -z "$name" ] || [ -z "$version" ]; then
        echo "错误: 项目名称和版本号不能为空" >&2
        exit 1
    fi
    
    ensure_file
    
    local temp_file="${VERSION_FILE}.tmp"
    
    if grep -q "^${name}|" "$VERSION_FILE" 2>/dev/null; then
        sed "s#^${name}|.*#${name}|${version}#" "$VERSION_FILE" > "$temp_file"
        mv "$temp_file" "$VERSION_FILE"
        echo "✓ 更新: ${name} → ${version}" >&2
    else
        echo "${name}|${version}" >> "$VERSION_FILE"
        echo "✓ 添加: ${name} → ${version}" >&2
    fi
    
    if [ -s "$VERSION_FILE" ]; then
        sort -u "$VERSION_FILE" > "$temp_file"
        mv "$temp_file" "$VERSION_FILE"
    fi
    
    rm -f "$temp_file"
}

# 检查是否存在
check_exists() {
    local name="$1"
    
    if [ -z "$name" ]; then
        echo "错误: 项目名称不能为空" >&2
        exit 1
    fi
    
    ensure_file
    grep -q "^${name}|" "$VERSION_FILE" 2>/dev/null
}

# 列出所有项目
list_all() {
    ensure_file
    
    if [ ! -s "$VERSION_FILE" ]; then
        echo "版本文件为空" >&2
        return 0
    fi
    
    echo "项目列表:" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    while IFS='|' read -r name version; do
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
