#!/bin/bash

set -e

# 环境变量
PLATFORMS="${PLATFORMS:-gitcode gitee gitlab r2}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")}"

# 自动设置默认值
USERNAME="${USERNAME:-whzhni}"
BRANCH="${BRANCH:-main}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

# 自动生成 UPLOAD_FILES
if [ -n "$DOWNLOAD_DIR" ] && [ -z "$UPLOAD_FILES" ]; then
    export UPLOAD_FILES="$(find "$DOWNLOAD_DIR" -type f 2>/dev/null | tr '\n' ' ')"
fi

# 自动生成 RELEASE_TITLE 和 RELEASE_BODY
if [ -z "$RELEASE_TITLE" ]; then
    export RELEASE_TITLE="${REPO_NAME} ${TAG_NAME}"
fi

if [ -z "$RELEASE_BODY" ]; then
    export RELEASE_BODY="## 📦 ${REPO_NAME} ${TAG_NAME}

### 📌 上游信息
- 项目: ${GITHUB_REPO_URL:-unknown}
- 同步时间: $(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')"
fi

# 导出变量供子脚本使用
export USERNAME
export BRANCH RUNNER_TEMP
export REPO_NAME TAG_NAME RELEASE_TITLE RELEASE_BODY UPLOAD_FILES

# 日志
log() { echo "🚀 $*" >&2; }

# 查找平台脚本
find_script() {
    local platform="$1"
    local script="$SCRIPTS_DIR/release-${platform}.sh"
    [ -f "$script" ] && echo "$script" || return 1
}

# 主函数
main() {
    log "并行发布到: $PLATFORMS"
    echo ""
    
    declare -A PIDS
    local count=0
    
    for platform in $PLATFORMS; do
        local script=$(find_script "$platform")
        
        if [ -z "$script" ]; then
            log "⚠️  跳过 $platform (脚本不存在)"
            continue
        fi
        
        chmod +x "$script"
        "$script" &
        PIDS[$platform]=$!
        
        log "  📤 $platform (PID: ${PIDS[$platform]})"
        count=$((count + 1))
    done
    
    [ $count -eq 0 ] && { log "❌ 没有可用的平台脚本"; exit 1; }
    
    echo ""
    log "等待所有平台完成..."
    echo ""
    
    declare -A RESULTS
    local success=0 failed=0
    
    for platform in "${!PIDS[@]}"; do
        wait ${PIDS[$platform]}
        RESULTS[$platform]=$?
        
        if [ ${RESULTS[$platform]} -eq 0 ]; then
            log "  $platform: ✅"
            success=$((success + 1))
        else
            log "  $platform: ❌"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    
    if [ $success -eq $count ]; then
        log "🎉 全部成功: $success/$count"
    elif [ $success -gt 0 ]; then
        log "⚠️  部分成功: $success/$count"
    else
        log "❌ 全部失败: $failed/$count"
        exit 1
    fi
}

main "$@"
