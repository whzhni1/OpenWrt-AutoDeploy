#!/bin/bash
# 删除仓库脚本 - 支持 GitCode/Gitee/GitLab/R2

set -e

# 删除单个平台
delete_platform() {
    local PLATFORM="$1"
    
    case "$PLATFORM" in
      gitcode)
        API="https://api.gitcode.com/api/v5/repos/${USERNAME}/${REPO_NAME}?access_token=${GITCODE_TOKEN}"
        ;;
      gitee)
        API="https://gitee.com/api/v5/repos/${USERNAME}/${REPO_NAME}?access_token=${GITEE_TOKEN}"
        ;;
      gitlab)
        API="https://gitlab.com/api/v4/projects/${USERNAME}%2F${REPO_NAME}"
        TOKEN="$GITLAB_TOKEN"
        ;;
      r2)
        echo "🗑️  删除 R2 存储: $REPO_NAME"
        
        export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY"
        export AWS_DEFAULT_REGION="auto"
        R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
        R2_BUCKET="${R2_BUCKET:-openwrt-autodeploy}"
        
        if aws s3 rm "s3://$R2_BUCKET/$REPO_NAME/" --recursive --endpoint-url="$R2_ENDPOINT" 2>&1 | grep -q "delete:"; then
          echo "✅ 删除成功"
        else
          echo "⚠️  删除失败或目录不存在"
        fi
        return 0
        ;;
      *)
        echo "❌ 未知平台: $PLATFORM"
        return 1
        ;;
    esac
    
    echo "🗑️  删除仓库: $PLATFORM - ${USERNAME}/${REPO_NAME}"
    
    if [ "$PLATFORM" = "gitlab" ]; then
      RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$API" -H "PRIVATE-TOKEN: $TOKEN")
    else
      RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$API")
    fi
    
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')
    
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "202" ]; then
      echo "✅ 删除成功"
    elif [ "$HTTP_CODE" = "404" ]; then
      echo "⚠️  仓库不存在"
    else
      echo "❌ 删除失败 (HTTP $HTTP_CODE): $BODY"
      return 1
    fi
}

# 主逻辑
main() {
    PLATFORMS="${PLATFORMS:-${1:-$PLATFORM}}"
    
    # 如果是多个平台，循环处理
    if echo "$PLATFORMS" | grep -q ' '; then
      for plat in $PLATFORMS; do
        delete_platform "$plat"
      done
    else
      delete_platform "$PLATFORMS"
    fi
}

main "$@"
