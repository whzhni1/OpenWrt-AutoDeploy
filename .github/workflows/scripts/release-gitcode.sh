#!/bin/bash

set -e

# 环境变量
GITCODE_TOKEN="${GITCODE_TOKEN:-}"
USERNAME="${USERNAME:-}"
REPO_NAME="${REPO_NAME:-}"
REPO_DESC="${REPO_DESC:-GitCode Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://api.gitcode.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"

# 日志
log() { echo "🅒🅞🅓🅔 $*" >&2; }

# API 调用
api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -H "PRIVATE-TOKEN: ${GITCODE_TOKEN}")
    
    [ "$method" = "POST" ] && args+=(-X POST -H "Content-Type: application/json" -d "$data")
    [ "$method" = "DELETE" ] && args+=(-X DELETE -o /dev/null -w "%{http_code}")
    
    curl "${args[@]}" "${API_BASE}${endpoint}"
}

check_env() {
    [ -z "$GITCODE_TOKEN" ] && { log "❌ GITCODE_TOKEN 未设置"; exit 1; }
    [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ] && { log "❌ USERNAME 或 REPO_NAME 未设置"; exit 1; }
    log "✅ 配置检查通过"
}

ensure_repo() {
    log "📦 步骤 1/4: 检查仓库"
    local resp=$(api GET "/repos/$REPO_PATH")
    
    if echo "$resp" | grep -q '"id"'; then
        log "✅ 仓库已存在"
        return 0
    fi
    
    log "⚠️  仓库不存在，创建中..."
    local private_val=$([ "$REPO_PRIVATE" = "true" ] && echo "true" || echo "false")
    local payload=$(jq -n --arg n "$REPO_NAME" --arg d "$REPO_DESC" --argjson p "$private_val" \
        '{name:$n, description:$d, private:$p, has_issues:true, has_wiki:true, auto_init:false}')
    
    resp=$(api POST "/user/repos" "$payload")
    echo "$resp" | grep -q '"id"' || { log "❌ 创建仓库失败"; exit 1; }
    log "✅ 仓库已创建"
    sleep 3
    
    log "🔧 初始化仓库..."
    local tmp="${RUNNER_TEMP:-/tmp}/gitcode-$$"
    mkdir -p "$tmp" && cd "$tmp"
    
    local readme="# ${REPO_NAME}

${REPO_DESC}

## 📦 Release
访问 [Releases](https://gitcode.com/${REPO_PATH}/releases) 下载构建产物。"
    
    local encoded=$(echo -n "$readme" | base64 | tr -d '\n')
    local file_payload=$(jq -n --arg msg "Initial commit" --arg content "$encoded" --arg branch "$BRANCH" \
        '{message:$msg, content:$content, branch:$branch}')
    
    local file_resp=$(api POST "/repos/$REPO_PATH/contents/README.md" "$file_payload")
    
    if echo "$file_resp" | jq -e '.commit.sha' >/dev/null 2>&1; then
        log "✅ 仓库初始化完成"
        cd - >/dev/null && rm -rf "$tmp"
        return 0
    fi
    
    log "⚠️  API 方式失败，使用 Git..."
    local git_url="https://oauth2:${GITCODE_TOKEN}@gitcode.com/${REPO_PATH}.git"
    
    if git clone "$git_url" . 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" | grep -q "Cloning"; then
        [ -f "README.md" ] && { log "✅ README.md 已存在"; cd - >/dev/null && rm -rf "$tmp"; return 0; }
        echo "$readme" > README.md
        git add README.md && git commit -m "Add README.md" -q
        git push 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" || { log "❌ 推送失败"; exit 1; }
    else
        git init -q
        git config user.name "GitCode Bot"
        git config user.email "bot@gitcode.com"
        echo "$readme" > README.md
        git add . && git commit -m "Initial commit" -q
        git remote add origin "$git_url"
        
        if ! git push -u origin HEAD:master 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" | grep -qv "error"; then
            git push -u origin HEAD:main 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" || { log "❌ 推送失败"; exit 1; }
        fi
    fi
    
    cd - >/dev/null && rm -rf "$tmp"
    log "✅ 仓库初始化完成"
}

cleanup_tags() {
    log "🧹 步骤 2/4: 清理旧标签"
    
    # 检查当前标签
    local current=$(api GET "/repos/$REPO_PATH/releases/tags/$TAG_NAME")
    if echo "$current" | grep -q "\"tag_name\":\"$TAG_NAME\""; then
        log "⏭️  Release 已存在 ($TAG_NAME)，跳过发布"
        return 2
    fi
    
    # 清理其他旧标签
    local tags=$(api GET "/repos/$REPO_PATH/tags" | jq -r '.[].name // empty' 2>/dev/null)
    [ -z "$tags" ] && { log "ℹ️  无需清理"; return 0; }
    
    local count=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        echo "$tag" | grep -qE '^(v[0-9]|[0-9])' || continue
        
        log "  🗑️  清理: $tag"
        local code=$(api DELETE "/repos/$REPO_PATH/tags/$tag")
        [ "$code" = "204" ] || [ "$code" = "200" ] && count=$((count + 1))
        sleep 0.5
    done <<< "$tags"
    
    [ $count -gt 0 ] && log "✅ 已清理 $count 个旧版本" || log "ℹ️  无需清理"
}

create_release() {
    log "🚀 步骤 3/4: 创建 Release (标签: $TAG_NAME)"
    
    api DELETE "/repos/$REPO_PATH/releases/tags/$TAG_NAME" >/dev/null 2>&1 || true
    
    local payload=$(jq -n --arg t "$TAG_NAME" --arg n "$RELEASE_TITLE" --arg b "$RELEASE_BODY" --arg br "$BRANCH" \
        '{tag_name:$t, name:$n, body:$b, target_commitish:$br}')
    
    local resp=$(api POST "/repos/$REPO_PATH/releases" "$payload")
    echo "$resp" | grep -q "\"tag_name\":\"$TAG_NAME\"" || { log "❌ 创建 Release 失败"; exit 1; }
    log "✅ Release 创建成功"
}

upload_file() {
    local file="$1"
    local name=$(basename "$file")
    
    log "  [$((uploaded + failed + 1))/$total] $name ($(du -h "$file" | cut -f1))"
    
    # 获取上传地址
    local info=$(curl -s "${API_BASE}/repos/$REPO_PATH/releases/$TAG_NAME/upload_url?access_token=$GITCODE_TOKEN&file_name=$name")
    echo "$info" | grep -q '"url"' || { log "  ❌ 获取上传地址失败"; return 1; }
    
    local url=$(echo "$info" | jq -r '.url')
    local project_id=$(echo "$info" | jq -r '.headers."x-obs-meta-project-id" // empty')
    local acl=$(echo "$info" | jq -r '.headers."x-obs-acl" // empty')
    local callback=$(echo "$info" | jq -r '.headers."x-obs-callback" // empty')
    local content_type=$(echo "$info" | jq -r '.headers."Content-Type" // "application/octet-stream"')
    
    # 上传文件
    local resp=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Type: $content_type" \
        -H "x-obs-meta-project-id: $project_id" \
        -H "x-obs-acl: $acl" \
        -H "x-obs-callback: $callback" \
        --data-binary "@$file" \
        "$url")
    
    local code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')
    
    [ "$code" = "200" ] || echo "$body" | grep -q "success"
}

upload_files() {
    log "📤 步骤 4/4: 上传文件"
    [ -z "$UPLOAD_FILES" ] && { log "ℹ️  无文件需要上传"; return; }
    
    uploaded=0 failed=0
    IFS=' ' read -ra files <<< "$UPLOAD_FILES"
    total=${#files[@]}
    
    for file in "${files[@]}"; do
        [ -z "$file" ] && continue
        if [ ! -f "$file" ]; then
            log "  ⚠️  文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        upload_file "$file" && uploaded=$((uploaded + 1)) || failed=$((failed + 1))
    done
    
    [ $uploaded -eq $total ] && log "✅ 全部上传成功: $uploaded/$total" || \
        log "⚠️  上传完成: 成功 $uploaded, 失败 $failed"
}

verify_release() {
    log "🔍 验证 Release"
    local resp=$(api GET "/repos/$REPO_PATH/releases/tags/$TAG_NAME")
    
    if echo "$resp" | grep -q "\"tag_name\":\"$TAG_NAME\""; then
        local assets=$(echo "$resp" | jq '.assets | length' 2>/dev/null || echo "?")
        log "✅ 验证成功 (附件: $assets)"
    else
        log "❌ 验证失败"
        exit 1
    fi
}

main() {
    log "🚀 GitCode Release 发布"
    log "📦 仓库: $REPO_PATH, 🏷️  标签: $TAG_NAME"
    
    check_env
    ensure_repo
    
    set +e
    cleanup_tags
    status=$?
    set -e
    
    [ $status -eq 2 ] && { log "✅ 发布完成"; exit 0; }
    
    create_release
    upload_files
    verify_release
    
    log "🎉 发布完成"
    log "🔗 https://gitcode.com/$REPO_PATH/releases"
}

main "$@"
