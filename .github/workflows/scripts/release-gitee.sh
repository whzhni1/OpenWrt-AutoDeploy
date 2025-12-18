#!/bin/bash

set -e

# 环境变量
GITEE_TOKEN="${GITEE_TOKEN:-}"
USERNAME="${USERNAME:-}"
REPO_NAME="${REPO_NAME:-}"
REPO_DESC="${REPO_DESC:-Gitee Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://gitee.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"
RELEASE_ID=""

# 日志
log() { echo "🅔🅔 $*" >&2; }

# API 调用
api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local url="${API_BASE}${endpoint}?access_token=${GITEE_TOKEN}"
    
    case "$method" in
        POST) curl -s -X POST -H "Content-Type: application/json" -d "$data" "$url" ;;
        DELETE) curl -s -o /dev/null -w "%{http_code}" -X DELETE "$url" ;;
        PATCH) curl -s -X PATCH -H "Content-Type: application/json" -d "$data" "$url" ;;
        *) curl -s "$url" ;;
    esac
}

check_env() {
    [ -z "$GITEE_TOKEN" ] && { log "❌ GITEE_TOKEN 未设置"; exit 1; }
    [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ] && { log "❌ USERNAME 或 REPO_NAME 未设置"; exit 1; }
    log "✅ 配置检查通过"
}

ensure_repo() {
    log "📦 步骤 1/4: 检查仓库"
    local resp=$(api GET "/repos/$REPO_PATH")
    
    if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
        local is_private=$(echo "$resp" | jq -r '.private')
        local visibility=$([ "$is_private" = "false" ] && echo "公开" || echo "私有")
        log "✅ 仓库已存在 ($visibility)"
        [ "$is_private" = "false" ] && return 0 || return 1
    fi
    
    log "⚠️  仓库不存在，创建中..."
    local payload=$(jq -n --arg n "$REPO_NAME" --arg d "$REPO_DESC" \
        '{name:$n, description:$d, has_issues:true, has_wiki:true, auto_init:false}')
    
    resp=$(api POST "/user/repos" "$payload")
    echo "$resp" | jq -e '.id' >/dev/null 2>&1 || { log "❌ 创建仓库失败"; exit 1; }
    log "✅ 仓库已创建"
    sleep 3
    
    log "🔧 初始化仓库..."
    local tmp="${RUNNER_TEMP:-/tmp}/gitee-$$"
    mkdir -p "$tmp" && cd "$tmp"
    
    cat > README.md <<EOF
# ${REPO_NAME}

${REPO_DESC}

## 📦 Release
访问 [Releases](https://gitee.com/${REPO_PATH}/releases) 下载构建产物。
EOF
    
    git init -q
    git config user.name "Gitee Bot"
    git config user.email "bot@gitee.com"
    git remote add origin "https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
    git add . && git commit -m "Initial commit" -q
    git push -u origin HEAD:"$BRANCH" 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g" || { log "❌ 初始化失败"; exit 1; }
    
    cd - >/dev/null && rm -rf "$tmp"
    log "✅ 仓库初始化完成"
    return 1
}

cleanup_tags() {
    log "🧹 步骤 2/4: 清理旧标签"
    
    # 检查当前标签
    local releases=$(api GET "/repos/$REPO_PATH/releases")
    local current=$(echo "$releases" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag) | .id // empty')
    if [ -n "$current" ] && [ "$current" != "null" ]; then
        log "⏭️  Release 已存在 ($TAG_NAME)，跳过发布"
        return 2
    fi
    
    # 清理其他旧标签
    local tmp="${RUNNER_TEMP:-/tmp}/gitee-cleanup-$$"
    mkdir -p "$tmp" && cd "$tmp"
    
    git init -q
    git config user.name "Gitee Bot"
    git config user.email "bot@gitee.com"
    git remote add origin "https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
    
    local tags=$(echo "$releases" | jq -r '.[].tag_name // empty')
    if [ -z "$tags" ]; then
        log "ℹ️  无需清理"
        cd - >/dev/null && rm -rf "$tmp"
        return 0
    fi
    
    local count=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        echo "$tag" | grep -qE '^(v[0-9]|[0-9])' || continue
        
        log "  🗑️  清理: $tag"
        if git push origin ":refs/tags/$tag" 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g" | grep -qv "error"; then
            count=$((count + 1))
        fi
        sleep 0.5
    done <<< "$tags"
    
    cd - >/dev/null && rm -rf "$tmp"
    [ $count -gt 0 ] && log "✅ 已清理 $count 个旧版本" || log "ℹ️  无需清理"
}

create_release() {
    log "🚀 步骤 3/4: 创建 Release (标签: $TAG_NAME)"
    
    local commit=$(api GET "/repos/$REPO_PATH/commits" | jq -r '.[0].sha // empty')
    [ -z "$commit" ] || [ "$commit" = "null" ] && { log "❌ 无法获取 commit"; exit 1; }
    
    local payload=$(jq -n --arg t "$TAG_NAME" --arg n "$RELEASE_TITLE" --arg b "$RELEASE_BODY" --arg c "$commit" \
        '{tag_name:$t, name:$n, body:$b, target_commitish:$c, prerelease:false}')
    
    local resp=$(api POST "/repos/$REPO_PATH/releases" "$payload")
    RELEASE_ID=$(echo "$resp" | jq -r '.id // empty')
    [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ] && { log "❌ 创建 Release 失败"; exit 1; }
    
    log "✅ Release 创建成功 (ID: $RELEASE_ID)"
}

upload_files() {
    log "📤 步骤 4/4: 上传文件"
    [ -z "$UPLOAD_FILES" ] && { log "ℹ️  无文件需要上传"; return; }
    [ -z "$RELEASE_ID" ] && { log "❌ RELEASE_ID 未设置"; exit 1; }
    
    local uploaded=0 failed=0
    IFS=' ' read -ra files <<< "$UPLOAD_FILES"
    
    for file in "${files[@]}"; do
        [ -z "$file" ] && continue
        if [ ! -f "$file" ]; then
            log "  ⚠️  文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        local name=$(basename "$file")
        log "  [$((uploaded + failed + 1))/${#files[@]}] $name ($(du -h "$file" | cut -f1))"
        
        local resp=$(curl -s -X POST \
            "$API_BASE/repos/$REPO_PATH/releases/$RELEASE_ID/attach_files" \
            -F "access_token=$GITEE_TOKEN" \
            -F "file=@$file")
        
        if echo "$resp" | jq -e '.browser_download_url' >/dev/null 2>&1; then
            uploaded=$((uploaded + 1))
        else
            log "  ❌ 上传失败: $(echo "$resp" | jq -r '.message // "未知错误"')"
            failed=$((failed + 1))
        fi
    done
    
    [ $uploaded -eq ${#files[@]} ] && log "✅ 全部上传成功: $uploaded/${#files[@]}" || \
        log "⚠️  上传完成: 成功 $uploaded, 失败 $failed"
}

verify_release() {
    log "🔍 验证 Release"
    local resp=$(api GET "/repos/$REPO_PATH/releases/tags/$TAG_NAME")
    
    if echo "$resp" | jq -e '.tag_name' >/dev/null 2>&1; then
        local assets=$(echo "$resp" | jq '.assets | length')
        log "✅ 验证成功 (附件: $assets)"
    else
        log "❌ 验证失败"
        exit 1
    fi
}

set_public() {
    log "🔓 设置仓库为公开"
    local payload=$(jq -n --arg n "$REPO_NAME" --arg d "$REPO_DESC" \
        '{name:$n, description:$d, private:false}')
    
    local resp=$(api PATCH "/repos/$REPO_PATH" "$payload")
    echo "$resp" | jq -e '.private' | grep -q "false" && log "✅ 已设置为公开" || log "⚠️  设置失败"
}

main() {
    log "🚀 Gitee Release 发布"
    log "📦 仓库: $REPO_PATH, 🏷️  标签: $TAG_NAME"
    
    check_env
    ensure_repo && is_public=0 || is_public=1
    
    set +e
    cleanup_tags
    status=$?
    set -e
    
    [ $status -eq 2 ] && { log "✅ 发布完成"; exit 0; }
    
    create_release
    upload_files
    verify_release
    [ $is_public -ne 0 ] && set_public
    
    log "🎉 发布完成"
    log "🔗 https://gitee.com/$REPO_PATH/releases/tag/$TAG_NAME"
}

main "$@"
