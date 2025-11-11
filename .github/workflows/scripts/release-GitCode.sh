#!/bin/bash

set -e

GITCODE_TOKEN="${GITCODE_TOKEN:-}"
USERNAME="${USERNAME:-whzhni}"
REPO_NAME="${REPO_NAME:-test-release}"
REPO_DESC="${REPO_DESC:-GitCode Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://gitcode.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

api_get() {
    local endpoint="$1"
    local url="${API_BASE}${endpoint}"
    [ "$url" == *"?"* ] && url="${url}&access_token=${GITCODE_TOKEN}" || url="${url}?access_token=${GITCODE_TOKEN}"
    
    response=$(curl -s -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 400 ]; then
        echo "$body"
        return 1
    fi
    
    echo "$body"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    local url="${API_BASE}${endpoint}"
    [ "$url" == *"?"* ] && url="${url}&access_token=${GITCODE_TOKEN}" || url="${url}?access_token=${GITCODE_TOKEN}"
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 400 ]; then
        echo "$body"
        return 1
    fi
    
    echo "$body"
}

api_delete() {
    local endpoint="$1"
    local url="${API_BASE}${endpoint}?access_token=${GITCODE_TOKEN}"
    
    response=$(curl -s -w "\n%{http_code}" -X DELETE "$url")
    http_code=$(echo "$response" | tail -n1)
    
    [ "$http_code" -eq 204 ] || [ "$http_code" -eq 200 ] || [ "$http_code" -eq 404 ]
}

upload_file_to_release() {
    local file="$1"
    local filename=$(basename "$file")
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    # 步骤1: 获取上传 URL
    log_debug "获取上传 URL..."
    local upload_url_endpoint="/repos/${USERNAME}/${REPO_NAME}/releases/${TAG_NAME}/upload_url"
    
    upload_info=$(api_get "${upload_url_endpoint}?file_name=${filename}")
    
    if [ $? -ne 0 ]; then
        log_error "获取上传 URL 失败"
        log_debug "Response: ${upload_info:0:200}"
        return 1
    fi
    
    # 步骤2: 提取 URL 和 headers
    if command -v jq &> /dev/null; then
        upload_url=$(echo "$upload_info" | jq -r '.url // empty')
        upload_headers=$(echo "$upload_info" | jq -r '.headers // empty')
    else
        upload_url=$(echo "$upload_info" | grep -o '"url":"[^"]*"' | head -1 | cut -d'"' -f4)
        upload_headers=$(echo "$upload_info" | grep -o '"headers":{[^}]*}' | sed 's/"headers"://')
    fi
    
    if [ -z "$upload_url" ]; then
        log_error "无法获取上传 URL"
        log_debug "Response: $upload_info"
        return 1
    fi
    
    log_debug "上传 URL: $upload_url"
    
    # 步骤3: 使用 PUT 上传文件
    log_debug "执行 PUT 上传..."
    
    # 构建 curl 命令，添加可能的 headers
    curl_cmd="curl -s -w \"\n%{http_code}\" -X PUT"
    
    # 如果有 headers，尝试解析并添加
    if [ -n "$upload_headers" ]; then
        if command -v jq &> /dev/null; then
            # 使用 jq 解析 headers
            while IFS= read -r header_line; do
                if [ -n "$header_line" ]; then
                    curl_cmd="$curl_cmd -H \"$header_line\""
                fi
            done < <(echo "$upload_headers" | jq -r 'to_entries[] | "\(.key): \(.value)"')
        fi
    fi
    
    # 执行上传
    response=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${file}" \
        "$upload_url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ] || [ "$http_code" -eq 204 ]; then
        log_success "上传成功"
        return 0
    else
        log_error "上传失败 (HTTP $http_code)"
        log_debug "Response: ${body:0:300}"
        return 1
    fi
}

check_token() {
    echo ""
    log_info "检查环境配置"
    
    if [ -z "$GITCODE_TOKEN" ]; then
        log_error "GITCODE_TOKEN 未设置"
        exit 1
    fi
    
    log_success "Token 已配置"
}

ensure_repository() {
    echo ""
    log_info "步骤 1/5: 检查仓库"
    
    if ! api_get "/repos/${REPO_PATH}" >/dev/null 2>&1; then
        log_warning "仓库不存在，创建中..."
        
        private_val="false"
        [ "$REPO_PRIVATE" = "true" ] && private_val="true"
        
        if ! api_post "/user/repos" "{
            \"name\": \"${REPO_NAME}\",
            \"description\": \"${REPO_DESC}\",
            \"private\": ${private_val},
            \"has_issues\": true,
            \"has_wiki\": true,
            \"auto_init\": false
        }" >/dev/null; then
            log_error "仓库创建失败"
            exit 1
        fi
        
        log_success "仓库创建成功"
        sleep 5
    else
        log_success "仓库已存在"
    fi
}

ensure_branch() {
    echo ""
    log_info "步骤 2/5: 检查分支"
    
    if api_get "/repos/${REPO_PATH}/branches/${BRANCH}" >/dev/null 2>&1; then
        log_success "分支已存在"
        return 0
    fi
    
    log_warning "分支不存在，创建中..."
    
    [ -f ".git/shallow" ] && { git fetch --unshallow || { rm -rf .git; git init; }; }
    [ ! -d ".git" ] && git init
    
    git config user.name "GitCode Bot"
    git config user.email "bot@gitcode.com"
    
    [ ! -f "README.md" ] && echo -e "# ${REPO_NAME}\n\n${REPO_DESC}" > README.md
    
    git add -A
    git diff --cached --quiet && git commit --allow-empty -m "Initial commit" || git commit -m "Initial commit"
    
    local git_url="https://oauth2:${GITCODE_TOKEN}@gitcode.com/${REPO_PATH}.git"
    git remote get-url gitcode &>/dev/null && git remote set-url gitcode "$git_url" || git remote add gitcode "$git_url"
    
    git push gitcode HEAD:refs/heads/${BRANCH} 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" || {
        log_error "推送失败"
        exit 1
    }
    
    log_success "分支创建成功"
    sleep 3
}

cleanup_old_tags() {
    echo ""
    log_info "步骤 3/5: 清理旧标签"
    
    response=$(api_get "/repos/${REPO_PATH}/tags" 2>/dev/null || echo "")
    tags=$(echo "$response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v "^$")
    
    if [ -z "$tags" ]; then
        log_info "没有旧标签"
        return 0
    fi
    
    deleted=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        log_warning "删除: $tag"
        api_delete "/repos/${REPO_PATH}/tags/${tag}" && { log_success "已删除"; deleted=$((deleted + 1)); }
        sleep 1
    done <<< "$tags"
    
    [ $deleted -gt 0 ] && log_info "已删除 $deleted 个旧标签"
}

create_release() {
    echo ""
    log_info "步骤 4/5: 创建 Release"
    log_info "标签: ${TAG_NAME}"
    log_info "标题: ${RELEASE_TITLE}"
    
    body_escaped=$(echo "$RELEASE_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    
    if ! response=$(api_post "/repos/${REPO_PATH}/releases" "{
        \"tag_name\": \"${TAG_NAME}\",
        \"name\": \"${RELEASE_TITLE}\",
        \"body\": \"${body_escaped}\",
        \"target_commitish\": \"${BRANCH}\"
    }"); then
        log_error "创建失败"
        exit 1
    fi
    
    if echo "$response" | grep -q "\"tag_name\":\"${TAG_NAME}\""; then
        log_success "Release 创建成功"
    else
        log_error "创建失败"
        exit 1
    fi
}

upload_files() {
    echo ""
    log_info "步骤 5/5: 上传文件到 Release"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    uploaded=0
    failed=0
    
    IFS=' ' read -ra FILES <<< "$UPLOAD_FILES"
    total=${#FILES[@]}
    
    for file in "${FILES[@]}"; do
        [ -z "$file" ] && continue
        
        if [ ! -f "$file" ]; then
            log_warning "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        echo ""
        log_info "[$(( uploaded + failed + 1 ))/${total}] $(basename "$file")"
        
        if upload_file_to_release "$file"; then
            uploaded=$((uploaded + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    log_success "上传完成: $uploaded 成功, $failed 失败"
}

verify_release() {
    echo ""
    log_info "验证 Release"
    
    if response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}"); then
        log_success "验证成功"
        
        # 显示附件信息
        if command -v jq &> /dev/null; then
            assets_count=$(echo "$response" | jq '.assets | length')
            [ "$assets_count" -gt 0 ] && log_info "附件数量: $assets_count"
        fi
    else
        log_error "验证失败"
        exit 1
    fi
}

main() {
    echo ""
    echo "GitCode Release 发布脚本"
    echo ""
    echo "仓库: ${REPO_PATH}"
    echo "标签: ${TAG_NAME}"
    
    check_token
    ensure_repository
    ensure_branch
    cleanup_old_tags
    create_release
    upload_files
    verify_release
    
    echo ""
    log_success "🎉 Release 创建完成"
    echo ""
    echo "访问: https://gitcode.com/${REPO_PATH}/releases"
    echo ""
}

main "$@"
