#!/bin/bash
set -e
USERNAME="${USERNAME:?❌ 错误: USERNAME 未设置}"
REPO_NAME="${REPO_NAME:?❌ 错误: REPO_NAME 未设置}"
TAG_NAME="${TAG_NAME:?❌ 错误: TAG_NAME 未设置}"
PLATFORMS="${PLATFORMS:-gitcode gitee gitlab r2}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
GITCODE_USERNAME="${GITCODE_USERNAME:-$USERNAME}"
GITEE_USERNAME="${GITEE_USERNAME:-$USERNAME}"
GITLAB_USERNAME="${GITLAB_USERNAME:-$USERNAME}"

# 批量处理并导出可选变量
for var in GITCODE_TOKEN GITEE_TOKEN GITLAB_TOKEN \
           R2_ACCOUNT_ID R2_ACCESS_KEY R2_SECRET_KEY R2_PUBLIC_URL \
           DOWNLOAD_DIR GITHUB_REPO_URL UPLOAD_FILES RELEASE_TITLE RELEASE_BODY; do
    export "$var"="${!var:-}"
done

# 自动生成内容
if [ -n "$DOWNLOAD_DIR" ] && [ -z "$UPLOAD_FILES" ]; then
    export UPLOAD_FILES="$(find "$DOWNLOAD_DIR" -type f 2>/dev/null | tr '\n' ' ')"
fi

if [ -z "$RELEASE_TITLE" ]; then
    export RELEASE_TITLE="${REPO_NAME} ${TAG_NAME}"
fi

if [ -z "$RELEASE_BODY" ]; then
    export RELEASE_BODY="## 📦 ${REPO_NAME} ${TAG_NAME}

### 📌 上游信息
- 项目: ${GITHUB_REPO_URL:-unknown}
- 同步时间: $(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')"
fi

# 导出其他必需变量
export USERNAME REPO_NAME TAG_NAME PLATFORMS RUNNER_TEMP
export GITCODE_USERNAME GITEE_USERNAME GITLAB_USERNAME

# 工具函数
log() { echo "🚀 $*" >&2; }

find_script() {
    local platform="$1"
    local script="$SCRIPTS_DIR/release-${platform}.sh"
    [ -f "$script" ] && echo "$script" || return 1
}

# 主函数
main() {
    log "发布配置:"
    log "  用户名: $USERNAME"
    log "  仓库: $REPO_NAME"
    log "  版本: $TAG_NAME"
    log "  平台: $PLATFORMS"
    echo ""
    
    declare -A PIDS
    local count=0
    
    for platform in $PLATFORMS; do
        local script=$(find_script "$platform")
        
        if [ -z "$script" ]; then
            log "⚠️  跳过 $platform (脚本不存在)"
            continue
        fi
        
        bash "$script" &
        PIDS[$platform]=$!
        
        log "  📤 $platform (PID: ${PIDS[$platform]})"
        count=$((count + 1))
    done
    
    if [ $count -eq 0 ]; then
        log "❌ 没有可用的平台脚本"
        exit 1
    fi
    
    echo ""
    log "等待发布完成..."
    
    declare -A RESULTS
    local success=0 failed=0
    
    for platform in "${!PIDS[@]}"; do
        wait ${PIDS[$platform]}
        RESULTS[$platform]=$?
        
        if [ ${RESULTS[$platform]} -eq 0 ]; then
            log "  $platform: ✅"
            success=$((success + 1))
        else
            log "  $platform: ❌ (退出码: ${RESULTS[$platform]})"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    log "发布完成: 成功 $success, 失败 $failed"
    
    # 如果所有平台都失败，返回错误
    [ $success -eq 0 ] && exit 1
    
    # 部分成功也返回 0（允许部分平台失败）
    return 0
}

main "$@"
