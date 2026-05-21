#!/bin/bash

set -e

# 环境变量
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY="${R2_ACCESS_KEY:-}"
R2_SECRET_KEY="${R2_SECRET_KEY:-}"
R2_BUCKET="${R2_BUCKET:-openwrt-autodeploy}"
R2_PUBLIC_URL="${R2_PUBLIC_URL:?❌ 错误: R2_PUBLIC_URL 未设置}"
REPO_NAME="${REPO_NAME:-}"
TAG_NAME="${TAG_NAME:-}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

# 日志
log() { echo "🆁❷ $*" >&2; }

# 配置 AWS CLI
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY"
export AWS_DEFAULT_REGION="auto"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# 检查环境
check_env() {
    [ -z "$R2_ACCESS_KEY" ] && { log "❌ R2_ACCESS_KEY 未设置"; exit 0; }
    [ -z "$R2_SECRET_KEY" ] && { log "❌ R2_SECRET_KEY 未设置"; exit 0; }
    [ -z "$R2_ACCOUNT_ID" ] && { log "❌ R2_ACCOUNT_ID 未设置"; exit 0; }
    [ -z "$REPO_NAME" ] || [ -z "$TAG_NAME" ] && { log "❌ REPO_NAME 或 TAG_NAME 未设置"; exit 0; }
    command -v aws >/dev/null 2>&1 || { log "❌ 需要 aws-cli"; exit 0; }
    log "✅ 环境检查通过"
}

# 检查版本并清理
check_version() {
    log "🔍 检查版本: $TAG_NAME"
    
    local releases_url="$R2_PUBLIC_URL/$REPO_NAME/releases"
    local existing=$(curl -sf "$releases_url" 2>/dev/null || echo "")
    
    if [ -n "$existing" ]; then
        if echo "$existing" | jq -e --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag)' >/dev/null 2>&1; then
            log "⏭️  版本 $TAG_NAME 已存在，跳过"
            return 1
        fi
        
        log "🧹 删除旧版本..."
        aws s3 ls "s3://$R2_BUCKET/$REPO_NAME/" --endpoint-url="$R2_ENDPOINT" | \
        awk '{print $2}' | grep -E '^v' | while read -r old_version; do
            old_version="${old_version%/}"
            [ -n "$old_version" ] && aws s3 rm "s3://$R2_BUCKET/$REPO_NAME/$old_version/" --recursive --endpoint-url="$R2_ENDPOINT" >/dev/null
            log "  ✓ 已删除 $old_version"
        done
    else
        log "📝 新项目"
    fi
    
    return 0
}

# 上传文件
upload_files() {
    log "📤 上传到 $REPO_NAME/$TAG_NAME/"
    
    local assets='[]'
    local uploaded=0
    
    IFS=' ' read -ra files <<< "$UPLOAD_FILES"
    
    for file in "${files[@]}"; do
        [ -z "$file" ] || [ ! -f "$file" ] && continue
        
        local name=$(basename "$file")
        local s3_path="s3://$R2_BUCKET/$REPO_NAME/$TAG_NAME/$name"
        local public_url="$R2_PUBLIC_URL/$REPO_NAME/$TAG_NAME/$name"
        
        log "  [$((uploaded + 1))/${#files[@]}] $name"
        
        if aws s3 cp "$file" "$s3_path" --endpoint-url="$R2_ENDPOINT" --no-progress >/dev/null 2>&1; then
            assets=$(echo "$assets" | jq -c \
            --arg name "$name" \
            --arg url "$public_url" \
            '. += [{name:$name, url:$url}]')
            uploaded=$((uploaded + 1))
        else
            log "  ❌ 上传失败: $name"
        fi
    done
    
    [ $uploaded -eq 0 ] && { log "❌ 没有文件上传成功"; exit 0; }
    
    log "✅ 已上传 $uploaded 个文件"
    
    log "📝 更新 releases 文件..."
    jq -n \
    --arg tag "$TAG_NAME" \
    --argjson count "$uploaded" \
    --argjson assets "$assets" \
    --arg sha256 "$(cat "${DOWNLOAD_DIR}/sha256.txt" 2>/dev/null || echo "")" \
    '[{tag_name:$tag, assets:{count:$count, files:$assets}, sha256:$sha256}]' > /tmp/releases
    
    aws s3 cp /tmp/releases "s3://$R2_BUCKET/$REPO_NAME/releases" \
        --endpoint-url="$R2_ENDPOINT" \
        --content-type "application/json" \
        --no-progress >/dev/null
    
    log "✅ releases 已更新"
}

main() {
    log "🚀 R2 上传: $REPO_NAME $TAG_NAME"
    
    check_env
    check_version || exit 0
    upload_files
    
    log "🎉 完成"
    log "📍 $R2_PUBLIC_URL/$REPO_NAME/"
}

main "$@"
