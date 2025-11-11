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
UPLOAD_METHOD="${UPLOAD_METHOD:-auto}"  # auto, release, repo

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

# 方法1: 上传到 Release 附件（需要 all_projects 权限）
upload_to_release() {
    local file="$1"
    local filename=$(basename "$file")
    
    log_debug "获取上传 URL..."
    
    upload_info=$(api_get "/repos/${USERNAME}/${REPO_NAME}/releases/${TAG_NAME}/upload_url?file_name=${filename}")
    
    if [ $? -ne 0 ]; then
        if echo "$upload_info" | grep -q "no scopes:all_projects"; then
            log_error "Token 缺少 all_projects 权限"
            return 2  # 返回 2 表示权限不足
        else
            log_error "获取上传 URL 失败"
            return 1
        fi
    fi
    
    if command -v jq &> /dev/null; then
        upload_url=$(echo "$upload_info" | jq -r '.url // empty')
    else
        upload_url=$(echo "$upload_info" | grep -o '"url":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    
    if [ -z "$upload_url" ]; then
        log_error "无法获取上传 URL"
        return 1
    fi
    
    log_debug "执行上传..."
    
    response=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${file}" \
        "$upload_url")
    
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ] || [ "$http_code" -eq 204 ]; then
        log_success "上传成功（Release 附件）"
        return 0
    else
        log_error "上传失败 (HTTP $http_code)"
        return 1
    fi
}

# 方法2: 上传到仓库文件（降级方案）
upload_to_repo() {
    local file="$1"
    local filename=$(basename "$file")
    
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    file_size_mb=$((file_size / 1024 / 1024))
    
    if [ $file_size_mb -gt 20 ]; then
        log_error "文件超过20M限制: $filename ($file_size_mb MB)"
        return 1
    fi
    
    log_debug "使用仓库文件上传接口..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -F "file=@${file}" \
        "${API_BASE}/repos/${USERNAME}/${REPO_NAME}/file/upload?access_token=${GITCODE_TOKEN}")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        if command -v jq &> /dev/null; then
            file_path=$(echo "$body" | jq -r '.path // .full_path // empty')
        else
            file_path=$(echo "$body" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
        
        log_success "上传成功（仓库文件）"
        
        if [ -n "$file_path" ]; then
            FILE_LINKS="${FILE_LINKS}\n- [${filename}](https://gitcode.com/${REPO_PATH}/blob/${BRANCH}/${file_path})"
        fi
        return 0
    else
        log_error "上传失败 (HTTP $http_code)"
        return 1
    fi
}

# 智能上传：自动选择方法
upload_file() {
    local file="$1"
    local filename=$(basename "$file")
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    # 根据配置选择上传方式
    if [ "$UPLOAD_METHOD" = "release" ]; then
        upload_to_release "$file"
    elif [ "$UPLOAD_METHOD" = "repo" ]; then
        upload_to_repo "$file"
    else
        # auto: 先尝试 release，失败则降级到 repo
        upload_to_release "$file"
        local result=$?
        
        if [ $result -eq 2 ]; then
            # 权限不足，降级
            log_warning "降级使用仓库文件上传"
            UPLOAD_METHOD="repo"  # 后续文件直接用这个方式
            upload_to_repo "$file"
        elif [ $result -ne 0 ]; then
            # 其他错误，尝试降级
            log_warning "尝试降级方案..."
            upload_to_repo "$file"
        fi
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
    log_info "步骤 5/5: 上传文件"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    uploaded=0
    failed=0
    FILE_LINKS=""
    
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
        
        if upload_file "$file"; then
            uploaded=$((uploaded + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    log_success "上传完成: $uploaded 成功, $failed 失败"
    
    # 如果使用了仓库文件上传，更新 Release 描述
    if [ "$UPLOAD_METHOD" = "repo" ] && [ -n "$FILE_LINKS" ]; then
        echo ""
        log_info "更新 Release 描述添加文件链接..."
        
        # 获取 Release ID
        rel_info=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}")
        
        if command -v jq &> /dev/null; then
            rel_id=$(echo "$rel_info" | jq -r '.id // empty')
        else
            rel_id=$(echo "$rel_info" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        fi
        
        if [ -n "$rel_id" ]; then
            new_body="${RELEASE_BODY}\n\n## 📦 发布文件${FILE_LINKS}"
            new_body_escaped=$(echo -e "$new_body" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
            
            response=$(curl -s -X PATCH \
                -H "Content-Type: application/json" \
                -d "{\"tag_name\":\"${TAG_NAME}\",\"name\":\"${RELEASE_TITLE}\",\"body\":\"${new_body_escaped}\"}" \
                "${API_BASE}/repos/${USERNAME}/${REPO_NAME}/releases/${rel_id}?access_token=${GITCODE_TOKEN}")
            
            echo "$response" | grep -q "\"tag_name\"" && log_success "描述已更新" || log_warning "描述更新失败"
        fi
    fi
}

verify_release() {
    echo ""
    log_info "验证 Release"
    
    if response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}"); then
        log_success "验证成功"
        
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
    echo "上传方式: ${UPLOAD_METHOD}"
    
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
    
    if [ "$UPLOAD_METHOD" = "repo" ]; then
        echo ""
        log_warning "注意: 使用了仓库文件上传（降级方案）"
        echo "建议重新生成 Token 并勾选 all_projects 权限以使用 Release 附件功能"
    fi
    echo ""
}

main "$@"
