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
    
    # 尝试获取上传 URL
    log_debug "请求上传 URL..."
    
    local url="${API_BASE}/repos/${USERNAME}/${REPO_NAME}/releases/${TAG_NAME}/upload_url?access_token=${GITCODE_TOKEN}&file_name=${filename}"
    
    response=$(curl -s -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    
    # 显示完整响应
    if [ "$http_code" -ne 200 ]; then
        log_error "获取上传 URL 失败"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "API 响应详情:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$body" | head -20
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # 分析错误
        if echo "$body" | grep -q "no scopes:all_projects"; then
            echo "❌ 错误原因: Token 缺少 'all_projects' scope"
            echo ""
            echo "GitCode API 文档说明该接口需要特殊权限，"
            echo "但 GitCode 网页令牌设置中可能没有提供这个选项。"
            echo ""
            echo "这可能是 GitCode 平台的限制："
            echo "- Release 附件上传功能可能仅对特定用户开放"
            echo "- 或者该 API 接口尚未完全开放"
            echo ""
        elif echo "$body" | grep -q "FORBIDDEN\|403"; then
            echo "❌ 错误原因: 权限不足 (403 Forbidden)"
            echo ""
        elif echo "$body" | grep -q "NOT_FOUND\|404"; then
            echo "❌ 错误原因: 接口不存在 (404 Not Found)"
            echo ""
            echo "可能的原因:"
            echo "- Release 尚未完全创建"
            echo "- API 路径不正确"
            echo "- 该功能未对你的账号开放"
            echo ""
        fi
        
        echo "建议操作:"
        echo "1. 访问 GitCode 官方文档确认 API 可用性"
        echo "2. 联系 GitCode 技术支持询问权限配置"
        echo "3. 暂时使用网页手动上传附件:"
        echo "   https://gitcode.com/${REPO_PATH}/releases"
        echo ""
        
        return 1
    fi
    
    # 检查响应是否为有效 JSON
    if ! echo "$body" | jq empty 2>/dev/null; then
        log_error "响应不是有效的 JSON"
        echo ""
        echo "响应内容:"
        echo "$body"
        return 1
    fi
    
    # 提取上传 URL
    upload_url=$(echo "$body" | jq -r '.url // empty')
    
    if [ -z "$upload_url" ]; then
        log_error "响应中没有 url 字段"
        echo ""
        echo "完整响应:"
        echo "$body" | jq . 2>/dev/null || echo "$body"
        return 1
    fi
    
    log_debug "上传 URL: ${upload_url:0:60}..."
    log_info "执行上传..."
    
    # 上传文件
    upload_response=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${file}" \
        "$upload_url")
    
    upload_http_code=$(echo "$upload_response" | tail -n1)
    
    if [ "$upload_http_code" -eq 200 ] || [ "$upload_http_code" -eq 201 ] || [ "$upload_http_code" -eq 204 ]; then
        log_success "上传成功"
        return 0
    else
        log_error "上传失败 (HTTP $upload_http_code)"
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
    
    if [ -z "$response" ] || ! echo "$response" | grep -q '\['; then
        log_info "没有旧标签"
        return 0
    fi
    
    if command -v jq &> /dev/null; then
        tags=$(echo "$response" | jq -r '.[].name' 2>/dev/null)
    else
        tags=$(echo "$response" | grep -o '{"name":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [ -z "$tags" ]; then
        log_info "没有旧标签"
        return 0
    fi
    
    deleted=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        if ! echo "$tag" | grep -qE '^(v[0-9]|[0-9])'; then
            continue
        fi
        
        log_warning "删除: $tag"
        
        if api_delete "/repos/${REPO_PATH}/tags/${tag}"; then
            log_success "已删除"
            deleted=$((deleted + 1))
        fi
        
        sleep 1
    done <<< "$tags"
    
    if [ $deleted -gt 0 ]; then
        log_info "已删除 $deleted 个旧标签"
    else
        log_info "没有需要删除的标签"
    fi
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
        
        # 等待 Release 完全创建
        log_info "等待 Release 初始化..."
        sleep 3
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
            # 第一个失败后就停止，避免重复显示错误
            break
        fi
    done
    
    echo ""
    
    if [ $uploaded -eq $total ]; then
        log_success "全部上传成功: $uploaded/$total"
    elif [ $uploaded -gt 0 ]; then
        log_warning "部分上传成功: $uploaded/$total"
    else
        log_error "上传失败"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "GitCode Release 附件上传功能当前不可用"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "根据错误信息，GitCode API 需要 'all_projects' scope，"
        echo "但令牌设置页面并未提供此选项。"
        echo ""
        echo "这可能意味着:"
        echo "• Release 附件上传功能尚未对普通用户开放"
        echo "• 需要企业版或特殊权限"
        echo "• API 文档与实际实现不一致"
        echo ""
        echo "建议:"
        echo "1. 手动上传: https://gitcode.com/${REPO_PATH}/releases"
        echo "2. 联系 GitCode 支持"
        echo "3. 或使用 GitHub/Gitee 作为主要发布平台"
        echo ""
    fi
}

verify_release() {
    echo ""
    log_info "验证 Release"
    
    if response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}"); then
        log_success "验证成功"
        
        if command -v jq &> /dev/null; then
            assets_count=$(echo "$response" | jq '.assets | length')
            log_info "附件数量: $assets_count"
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
