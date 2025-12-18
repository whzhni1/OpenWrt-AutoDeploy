#!/bin/bash

set -e

# 环境变量
PLATFORMS="${PLATFORMS:-gitcode gitee gitlab r2}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")}"

# 日志
log() { echo "🚀 $*" >&2; }

# 查找平台脚本
find_script() {
    local platform="$1"
    local script="$SCRIPTS_DIR/release-${platform}.sh"
    
    if [ -f "$script" ]; then
        echo "$script"
        return 0
    fi
    
    return 1
}

# 主函数
main() {
    log "并行发布到: $PLATFORMS"
    echo ""
    
    declare -A PIDS
    local count=0
    
    # 启动所有平台脚本
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
            log "  $platform: ❌ (退出码: ${RESULTS[$platform]})"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    
    if [ $success -eq $count ]; then
        log "🎉 全部成功: $success/$count"
        exit 0
    elif [ $success -gt 0 ]; then
        log "⚠️  部分成功: $success/$count (失败: $failed)"
        exit 0
    else
        log "❌ 全部失败: $failed/$count"
        exit 1
    fi
}

main "$@"
