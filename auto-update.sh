#!/bin/sh

SCRIPT_VERSION="2.3.3"
LOG_FILE="/tmp/auto-update.log"
CONFIG_FILE="/etc/auto-setup.conf"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"
DEFAULT_EXCLUDE="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky luci-app-openlist2 luci-app-tailscale luci-app-vnt"

# 批量初始化变量
for var in ASSETS_JSON_CACHE INSTALLED_LIST OFFICIAL_PACKAGES NON_OFFICIAL_PACKAGES OFFICIAL_DETAIL THIRDPARTY_DETAIL; do
    eval "$var=''"
done

for var in OFFICIAL_UPDATED OFFICIAL_SKIPPED OFFICIAL_FAILED THIRDPARTY_UPDATED THIRDPARTY_SAME THIRDPARTY_FAILED excluded; do
    eval "$var=0"
done

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t "auto-update" "$1" 2>/dev/null || true
}

# 加载配置
load_config() {
    [ ! -f "$CONFIG_FILE" ] && { log "✗ 配置文件不存在"; return 1; }
    . "$CONFIG_FILE"

    [ -z "$SYS_ARCH" ] || [ -z "$PKG_INSTALL" ] || [ -z "$PKG_UPDATE" ] || \
    [ -z "$PKG_LIST_INSTALLED" ] || [ -z "$SCRIPT_URLS" ] && { log "✗ 缺少必需配置"; return 1; }
    EXCLUDE_LIST="$DEFAULT_EXCLUDE $EXCLUDE_PACKAGES"
    log "√ 配置已加载"
}

# 解析 Git 信息
parse_git_info() {
    local input="$1"
    
    url="${input%%≈*}"
    token="${input#*≈}"
    [ "$token" = "$input" ] && token=""
    case "$url" in *".r2.dev"*) platform="cloudflare"; owner=""; return ;; esac
    local norm="${url/raw.gitcode/gitcode}"
    norm="${norm/raw.githubusercontent.com/github.com}"
    platform=$(echo "$norm" | sed -n 's|.*://\([^.]*\)\..*|\1|p')
    owner=$(echo "$norm" | sed -n 's|.*://[^/]*/\([^/]*\)/.*|\1|p')
}

# 工具函数
normalize_version() { echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'; }
format_size() {
    local b="$1"
    [ $b -gt 1048576 ] && echo "$((b/1048576)) MB" && return
    [ $b -gt 1024 ] && echo "$((b/1024)) KB" && return
    echo "$b 字节"
}

# 版本比较
version_greater() {
    local v1=$(normalize_version "$1") v2=$(normalize_version "$2")
    [ "$v1" = "$v2" ] && return 1
    [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)" = "$v1" ]
}

# 验证下载文件
validate_file() {
    local file="$1" min="${2:-1024}"
    [ ! -f "$file" ] || [ ! -s "$file" ] && { log "⚠ 文件无效"; return 1; }
    
    local size=$(wc -c < "$file" | tr -d ' ')
    [ $size -lt $min ] && head -1 "$file" | grep -qi "<!DOCTYPE\|<html" && {
        log "✗ 下载的是HTML"
        return 1
    }
    
    log "√ 文件有效: $(format_size $size)"
}

# API 调用
api_get_release() {
    local platform="$1" owner="$2" repo="$3" header result
    
    case "$platform" in
        cloudflare)
            url="$(echo "$url" | sed "s|/auto-setup$|/${repo}/releases|")"
            ;;
        gitlab)
            url="https://gitlab.com/api/v4/projects/${owner}%2F${repo}/releases"
            header="PRIVATE-TOKEN: $token"
            ;;
        github)
            url="https://api.github.com/repos/${owner}/${repo}/releases"
            header="Authorization: token $token"
            ;;
        *)
            url="https://${platform}.com/api/v5/repos/${owner}/${repo}/releases"
            header="Authorization: Bearer $token"
            ;;
    esac
    
    ([ -n "$token" ] && curl -s --connect-timeout 5  -H "$header" "$url" || curl -s --connect-timeout 5  "$url") | sed 's/": /":/g'
}

# 查找并安装
find_and_install() {
    local app="$1"

    local all_files=$(echo "$ASSETS_JSON_CACHE" | grep -o "\"[^\"]*${PKG_EXT}\"" | tr -d '"' | grep -v "/" | grep -v "sha256")
    [ -z "$all_files" ] && { log "✗ 未找到文件"; return 1; }
    log "  共 $(echo "$all_files" | wc -l) 个文件"
    
    local count=0
    
    for arch in $SYS_ARCH $ARCH_FALLBACK; do
        local file=$(echo "$all_files" | grep -v "^luci-" | grep -i "$app" | grep "$arch" | head -1)
        [ -n "$file" ] && {
            log "  [架构包] $file"
            download_and_install "$file" && count=$((count+1))
            break
        }
    done

    local file=$(echo "$all_files" | grep -E "^luci-(app|theme)-${app}[-_]" | head -1)
    [ -n "$file" ] && {
        log "  [Luci包] $file"
        download_and_install "$file" && count=$((count+1))
    }

    local file=$(echo "$all_files" | grep "zh-cn" | grep -i "$app" | head -1)
    [ -n "$file" ] && {
        log "  [语言包] $file"
        download_and_install "$file" && count=$((count+1))
    }
    
    [ $count -gt 0 ]
}

# 获取下载地址
get_download_url() {
    echo "$ASSETS_JSON_CACHE" | grep -o "https://[^\"]*$1" | grep -v "sha256" | grep -v "\\\\n" | head -1 | sed 's/api\.gitcode/gitcode/g'
}

# 下载并安装
download_and_install() {
    local file="$1"
    local url=$(get_download_url "$file")
    [ -z "$url" ] && { log "✗ 无下载地址"; return 1; }
    
    log "    下载: $file"
    curl -fsSL --connect-timeout 5 --max-time 60 -o "/tmp/$file" "$url" || { log "⚠ 下载失败"; return 1; }
    
    validate_file "/tmp/$file" 10240 || { rm -f "/tmp/$file"; return 1; }
    
    log "    安装: $file"
    $PKG_INSTALL "/tmp/$file" >>"$LOG_FILE" 2>&1 && {
        log "√ 安装成功"
        rm -f "/tmp/$file"
        return 0
    } || {
        log "✗ 安装失败: $(tail -1 "$LOG_FILE" | grep -v '^\[')"
        return 1
    }
}

# 处理单个包
process_package() {
    local pkg="$1" check_ver="${2:-0}" cur_ver="$3"
    log "处理包: $pkg"

    local app=$(echo "$pkg" | sed 's/^luci-app-//' | sed 's/^luci-theme-//')
    
    for src in $SCRIPT_URLS; do
        parse_git_info "$src"
        [ "$platform" = "cloudflare" ] && authors="R2" || authors="${AUTHORS:-$owner}"
        
        for author in $authors; do
            log "  尝试: $platform/$author/$pkg"
            local json=$(api_get_release "$platform" "$author" "$pkg")
            echo "$json" | grep -q '\[' || { log "  ⚠ 无效响应"; continue; }
            
            local ver=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -z "$ver" ] && { log "  ⚠ 无版本信息"; continue; }
            log "  最新版本: $ver"
            
            if [ "$check_ver" = "1" ]; then
                version_greater "$ver" "$cur_ver" || { log "  ○ 已是最新 ($cur_ver)"; return 2; }
                log "  发现更新: $cur_ver → $ver"
            fi
            
            echo "$json" | grep -q '"assets"' || { log "  ⚠ 无资源文件"; continue; }

            ASSETS_JSON_CACHE="$json"
            find_and_install "$app" && { log "√ $pkg 安装成功"; return 0; }
            log "  ✗ 无匹配文件"
        done
    done
    
    log "✗ 所有源均失败"
    return 1
}

# 保存第三方包列表
save_third_party() {
    [ ! -f "$CONFIG_FILE" ] && return
    local old=$(sed -n 's/^THIRD_PARTY_INSTALLED="\(.*\)"/\1/p' "$CONFIG_FILE")
    local new=$(echo "$old $1" | xargs | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
    
    grep -q "^THIRD_PARTY_INSTALLED=" "$CONFIG_FILE" && \
        sed -i "s|^THIRD_PARTY_INSTALLED=.*|THIRD_PARTY_INSTALLED=\"$new\"|" "$CONFIG_FILE" || \
        printf '\n# 第三方源安装的包\nTHIRD_PARTY_INSTALLED="%s"\n' "$new" >> "$CONFIG_FILE"
    
    log "√ 配置已更新"
}

# install 模式
run_install() {
    log "第三方源安装模式"
    log "包列表: $*"
    
    load_config || return 1
    for pkg in "$@"; do
        log ""
        if process_package "$pkg" 0; then
            THIRDPARTY_DETAIL="${THIRDPARTY_DETAIL}\n√ $pkg"
            THIRDPARTY_UPDATED=$((THIRDPARTY_UPDATED+1))
            INSTALLED_LIST="$INSTALLED_LIST $pkg"
        else
            THIRDPARTY_DETAIL="${THIRDPARTY_DETAIL}\n✗ $pkg"
            THIRDPARTY_FAILED=$((THIRDPARTY_FAILED+1))
        fi
    done
    
    INSTALLED_LIST=$(echo "$INSTALLED_LIST" | xargs)
    [ -n "$INSTALLED_LIST" ] && save_third_party "$INSTALLED_LIST"
    
    log ""
    log "安装汇总: 成功 $THIRDPARTY_UPDATED, 失败 $THIRDPARTY_FAILED"
    
    generate_report "install"
    log ""
    echo -e "$REPORT"
    send_push "$DEVICE_MODEL - 包安装结果" "$REPORT"
    
    [ $THIRDPARTY_FAILED -eq 0 ]
}

is_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for p in $EXCLUDE_LIST; do case "$1" in $p*) return 0 ;; esac; done
    return 1
}

get_version() {
    local pkg="$1" src="${2:-installed}"
    [ "$src" = "installed" ] && \
        $PKG_LIST_INSTALLED 2>/dev/null | awk -v p="$pkg" '$1==p {print $3; exit}' || \
        $PKG_LIST "$pkg" 2>/dev/null | awk -v p="$pkg" '$1==p {print $3; exit}'
}

install_lang() {
    local pkg="$1" lang=""
    case "$pkg" in
        luci-app-*) lang="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return ;;
    esac
    
    $PKG_LIST "$lang" 2>/dev/null | grep -q "^$lang " || return
    $PKG_INSTALL "$lang" >>"$LOG_FILE" 2>&1 && log "√ $lang 安装成功"
}

# 分类包
classify_packages() {
    $PKG_UPDATE >>"$LOG_FILE" 2>&1 && log "√ 软件源已更新" || log "⚠ 软件源更新失败"
    log "🔍 正在识别包来源…"
    local all=$($PKG_LIST_INSTALLED 2>/dev/null | awk '{print $1}' | grep -v "^luci-i18n-")
    
    for pkg in $all; do
        is_excluded "$pkg" && { excluded=$((excluded+1)); continue; }
        
        case " $THIRD_PARTY_INSTALLED " in *" $pkg "*) NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"; continue ;; esac
        
        $PKG_INFO "$pkg" 2>/dev/null | grep -q "^Description:" && \
            OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg" || \
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
    done
    [ -z "$OFFICIAL_PACKAGES" ] && {
        log "⚠ 软件源异常，回退到已知第三方列表"
        NON_OFFICIAL_PACKAGES="$THIRD_PARTY_INSTALLED"
    }
    log "包分类: 官方 $(echo $OFFICIAL_PACKAGES|wc -w), 第三方 $(echo $NON_OFFICIAL_PACKAGES|wc -w), 排除 $excluded"
}

# 更新官方包
update_official() {
    log "步骤: 更新官方源"
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_version "$pkg" installed)
        local new=$(get_version "$pkg" available)
        
        [ "$cur" != "$new" ] && [ -n "$new" ] && {
            log "↻ $pkg: $cur → $new"
            $PKG_INSTALL "$pkg" >>"$LOG_FILE" 2>&1 && {
                log "√ 升级成功"
                OFFICIAL_DETAIL="${OFFICIAL_DETAIL}\n√ $pkg: $cur → $new"
                OFFICIAL_UPDATED=$((OFFICIAL_UPDATED+1))
                install_lang "$pkg"
            } || {
                log "✗ 升级失败"
                OFFICIAL_DETAIL="${OFFICIAL_DETAIL}\n✗ $pkg: $cur → $new"
                OFFICIAL_FAILED=$((OFFICIAL_FAILED+1))
            }
        } || {
            log "○ $pkg: $cur → $cur"
            OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED+1))
        }
    done
    
    log "官方源: 升级 $OFFICIAL_UPDATED, 最新 $OFFICIAL_SKIPPED, 失败 $OFFICIAL_FAILED"
}

# 更新第三方包
update_thirdparty() {
    log "步骤: 更新第三方源"
    
    [ -z "$NON_OFFICIAL_PACKAGES" ] && { log "无第三方包"; return; }
    
    log "检查 $(echo $NON_OFFICIAL_PACKAGES|wc -w) 个第三方包"
    
    for pkg in $NON_OFFICIAL_PACKAGES; do
        local cur=$(get_version "$pkg" installed)
        log "🔍 $pkg (当前: $cur)"
        
        process_package "$pkg" 1 "$cur"
        case $? in
            0) 
                local new=$(get_version "$pkg" installed)
                THIRDPARTY_DETAIL="${THIRDPARTY_DETAIL}\n√ $pkg: $cur → $new"
                THIRDPARTY_UPDATED=$((THIRDPARTY_UPDATED+1)) 
                ;;
            2) THIRDPARTY_SAME=$((THIRDPARTY_SAME+1)) ;;
            *) 
                THIRDPARTY_DETAIL="${THIRDPARTY_DETAIL}\n✗ $pkg"
                THIRDPARTY_FAILED=$((THIRDPARTY_FAILED+1)) 
                ;;
        esac
    done
    
    log "第三方源: 更新 $THIRDPARTY_UPDATED, 最新 $THIRDPARTY_SAME, 失败 $THIRDPARTY_FAILED"
}

# 检查脚本更新
check_script_update() {
    log "当前版本: $SCRIPT_VERSION"
    local tmp="/tmp/auto-update-new.sh"

    for url in $SCRIPT_URLS; do
        local update_url=$(echo "$url" | sed 's/auto-setup.*/auto-update.sh/')

        curl -fsSL --max-time 3 -o "$tmp" "$update_url" 2>/dev/null || continue
        grep -q "run_update" "$tmp" || { rm -f "$tmp"; continue; }
        
        local ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$tmp" | head -1)
        [ -z "$ver" ] && continue
        [ "$SCRIPT_VERSION" = "$ver" ] && { rm -f "$tmp"; return; }

        version_greater "$ver" "$SCRIPT_VERSION" && {
            log "↻ 发现新版本: $SCRIPT_VERSION → $ver"
            mv "$tmp" "$(readlink -f "$0")" && chmod +x "$(readlink -f "$0")" && {
                log "√ 更新成功，重启脚本"
                exec "$(readlink -f "$0")" "$@"
            }
        }
        rm -f "$tmp"
    done
}

# 推送
send_push() {
    [ -z "$PUSH_TOKEN" ] && return 
    local token="$PUSH_TOKEN" url
    case "$token" in
        SCU*)      url="https://sc.ftqq.com/${token}.send" ;;
        sct*|SCT*) url="https://sctapi.ftqq.com/${token}.send" ;;
        *)         url="http://www.pushplus.plus/send" ;;
    esac
    log "发送推送..."
    case "$token" in
        SCU*|sct*|SCT*)
            curl -s -X POST "$url" -d "text=$1" -d "desp=$2" | \
                grep -q '"errno":0\|"code":0' && log "√ 推送成功"
            ;;
        *)
            local c=$(echo "$2" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
            curl -s -X POST "$url" -H "Content-Type: application/json" \
                -d "{\"token\":\"$token\",\"title\":\"$1\",\"content\":\"$c\",\"template\":\"txt\"}" | \
                grep -q '"code":200' && log "√ 推送成功"
            ;;
    esac
}

# 生成报告
generate_report() {
    local mode="$1"
    local cron=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -1)
    local schedule="未设置"
    
    if [ -n "$cron" ]; then
        set -- $(echo "$cron" | awk '{print $1, $2, $5}')
        case "$3" in
            [0-6]) schedule="每周$(echo $3|sed 's/0/日/;s/1/一/;s/2/二/;s/3/三/;s/4/四/;s/5/五/;s/6/六/') $(printf "%02d:%02d" ${2:-0} ${1:-0})" ;;
            *) echo "$2"|grep -q "^\*/" && schedule="每$(echo $2|sed 's#\*/##')小时" || [ "$2" != "*" ] && schedule="每天 $(printf "%02d:%02d" $2 ${1:-0})" ;;
        esac
    fi
    
    REPORT="脚本版本: $SCRIPT_VERSION\n时间: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    [ "$mode" != "install" ] && {
        REPORT="${REPORT}官方源: √ $OFFICIAL_UPDATED ○ $OFFICIAL_SKIPPED ✗ $OFFICIAL_FAILED${OFFICIAL_DETAIL}\n"
    }
    
    REPORT="${REPORT}第三方:√ $THIRDPARTY_UPDATED ○ $THIRDPARTY_SAME ✗ $THIRDPARTY_FAILED${THIRDPARTY_DETAIL}\n"
    [ "$mode" = "install" ] && [ "$INSTALL_PRIORITY" = "1" ] && [ "$THIRDPARTY_FAILED" -gt 0 ] && {
        REPORT="${REPORT}⚠ 失败的包将由官方源继续安装\n"
    }
    REPORT="${REPORT}⏰ 自动更新: $schedule\n\n详细日志: $LOG_FILE"
}

# update 模式
run_update() {
    > "$LOG_FILE"
    log "OpenWrt 自动更新 v$SCRIPT_VERSION"
    
    load_config || return 1
    log "架构: $SYS_ARCH | 包管理: $PKG_TYPE | 策略: $([ "$INSTALL_PRIORITY" = "1" ] && echo 三方优先 || echo 官方优先)"
    
    check_script_update
    classify_packages || return 1
    
    [ "$INSTALL_PRIORITY" = "1" ] && {
        update_thirdparty
        update_official
    } || {
        update_official
        update_thirdparty

    }
    
    log "√ 更新完成"
    generate_report "update"
    echo -e "$REPORT"
    send_push "$PUSH_TITLE" "$REPORT"
}

case "$1" in
    install) shift; run_install "$@" ;;
    *) run_update ;;
esac
