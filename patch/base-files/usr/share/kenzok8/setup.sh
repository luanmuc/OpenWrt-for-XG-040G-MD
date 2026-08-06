#!/bin/sh
# ============================================================
# kenzok8 第三方插件源自动配置主脚本（apk 版）
#
# 功能：自动检测系统架构，添加 kenzok8/dllkids 二进制源并更新包列表
# 设计原则：
#   1. 幂等安全：已执行成功则直接退出，重复执行无副作用
#   2. 容错兜底：所有异常全部捕获，永远不抛错影响系统
#   3. 可追溯：日志输出到 /tmp，重启自动清理不占闪存
#   4. 可禁用：删除 /etc/kenzok8.done 可重新触发，删除脚本即可完全移除
#
# 适用：OpenWrt 25.12+ (apk 包管理器)
# 对齐：https://down.dllkids.xyz/openwrt-feed/openwrt-feed-setup.sh
# ============================================================

# -------------------------- 配置区 --------------------------
# 成功标记文件（持久化，成功一次永久生效）
DONE_MARK="/etc/kenzok8.done"
# 源配置文件（单独文件，不混入系统默认源）
REPO_FILE="/etc/apk/repositories.d/kenzok8.list"
# 日志文件（临时目录，重启自动清理）
LOG_FILE="/tmp/kenzok8.log"
# apk update 超时时间（秒）
UPDATE_TIMEOUT=60
# 源基础地址
BASE_URL="https://down.dllkids.xyz/openwrt-feed"
# SDK 版本（25.12 对应 apk-tools v3）
SDK="25.12"
# ECDSA 公钥 URL 与目标路径
KEY_URL="${BASE_URL}/keys/dllkids-feed.pub.pem"
KEY_FILE="/etc/apk/keys/dllkids-feed.pub.pem"

# -------------------------- 函数区 --------------------------
# 日志输出函数：统一格式，带时间戳
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# 安全退出函数：确保永远返回0
safe_exit() {
    exit 0
}

# 文件下载：依次尝试 wget / uclient-fetch / curl
fetch_file() {
    url="$1"; out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url" 2>/dev/null && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$out" "$url" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out" 2>/dev/null && return 0
    fi
    return 1
}

# 检测 URL 是否可访问（真实 GET 请求，避免 CDN HEAD 302 误判）
url_exists() {
    url="$1"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null "$url" 2>/dev/null && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O /dev/null "$url" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o /dev/null "$url" 2>/dev/null && return 0
    fi
    return 1
}

# 清理文件中所有旧的 dllkids 行（防止旧版残留导致 404）
clean_dllkids_lines() {
    file="$1"
    [ -e "$file" ] || return 0
    tmpf="${file}.kenzok8.tmp"
    grep -vF 'down.dllkids.xyz/openwrt-feed/' "$file" > "$tmpf" 2>/dev/null || true
    mv "$tmpf" "$file" 2>/dev/null || true
}

# 检测架构：优先 DISTRIB_ARCH，兜底 apk --print-arch
detect_arch() {
    ARCH=""
    # 优先从 /etc/openwrt_release 读取完整架构名（如 aarch64_cortex-a53）
    if [ -f /etc/openwrt_release ]; then
        ARCH=$(sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release 2>/dev/null | head -n1)
    fi
    # 兜底：apk --print-arch 只返回 CPU family（如 aarch64）
    if [ -z "$ARCH" ] && command -v apk >/dev/null 2>&1; then
        ARCH=$(apk --print-arch 2>/dev/null)
    fi
    echo "$ARCH"
}

# 生成候选架构列表（精确 → 通用 → all）
candidate_arches() {
    requested_arch="$1"
    printf '%s\n' "$requested_arch"
    case "$requested_arch" in
        aarch64|arm64|aarch64_*)
            [ "$requested_arch" = "aarch64_generic" ] || printf '%s\n' "aarch64_generic"
            ;;
    esac
    printf '%s\n' "all"
}

# 选择可用的 feed 架构（逐级降级验证）
select_feed_arch() {
    requested_arch="$1"
    SDK_URL="${BASE_URL}/${SDK}"
    seen=" "
    for candidate in $(candidate_arches "$requested_arch"); do
        case "$seen" in
            *" $candidate "*) continue ;;
        esac
        seen="${seen}${candidate} "
        candidate_url="${SDK_URL}/${candidate}"
        if url_exists "${candidate_url}/packages.adb"; then
            if [ "$candidate" != "$requested_arch" ]; then
                log "警告: 架构 '${requested_arch}' 无对应源，降级到 '${candidate}'"
            fi
            SELECTED_ARCH="$candidate"
            SELECTED_ARCH_URL="$candidate_url"
            return 0
        fi
    done
    log "错误: 在 ${SDK_URL} 下未找到 '${requested_arch}' 可用的 apk 源"
    return 1
}

# -------------------------- 主逻辑 --------------------------
# 第一步：幂等检查 - 已成功配置过则直接退出
if [ -f "$DONE_MARK" ]; then
    safe_exit
fi

# 初始化日志
mkdir -p /tmp 2>/dev/null || true
log "========== kenzok8 源配置脚本启动 =========="

# 第二步：确认 apk 包管理器可用
if ! command -v apk >/dev/null 2>&1; then
    log "错误: 未检测到 apk 包管理器，本脚本仅支持 OpenWrt 25.12+"
    safe_exit
fi
log "包管理器: apk (SDK ${SDK})"

# 第三步：检测系统架构
ARCH=$(detect_arch)
if [ -z "$ARCH" ]; then
    log "错误: 无法获取系统架构"
    safe_exit
fi
log "检测到架构: ${ARCH}"

# 第四步：选择可用的 feed 架构（逐级降级）
SDK_URL="${BASE_URL}/${SDK}"
SELECTED_ARCH=""
SELECTED_ARCH_URL=""
if ! select_feed_arch "$ARCH"; then
    log "错误: 没有可用的源架构，退出"
    safe_exit
fi
log "最终选用架构: ${SELECTED_ARCH}"
log "源地址: ${SELECTED_ARCH_URL}/packages.adb"

# 第五步：下载并安装 ECDSA PEM 公钥
log "正在下载 ECDSA 公钥: ${KEY_URL}"
mkdir -p /etc/apk/keys 2>/dev/null || true
if fetch_file "$KEY_URL" "$KEY_FILE"; then
    chmod 644 "$KEY_FILE" 2>/dev/null || true
    log "公钥安装成功: ${KEY_FILE}"
else
    log "警告: 公钥下载失败，将使用 --allow-untrusted 模式"
fi

# 第六步：写入源配置文件
# 先清理所有 repositories.d/*.list 和主 repositories 中的旧 dllkids 行
clean_dllkids_lines "/etc/apk/repositories"
for f in /etc/apk/repositories.d/*.list; do
    [ -e "$f" ] || continue
    clean_dllkids_lines "$f"
done

# 确保目录存在
mkdir -p /etc/apk/repositories.d 2>/dev/null || true

# 写入新的源配置（直接指向 packages.adb，apk-tools v3 规范格式）
{
    echo "# kenzok8 第三方插件源 - 自动配置"
    echo "# 架构: ${SELECTED_ARCH}"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "${SELECTED_ARCH_URL}/packages.adb"
} > "$REPO_FILE" 2>/dev/null

if [ $? -eq 0 ]; then
    log "源配置写入成功: ${REPO_FILE}"
else
    log "错误: 源配置写入失败"
    safe_exit
fi

# 第七步：执行 apk update
log "开始执行 apk update（超时 ${UPDATE_TIMEOUT}秒）..."

# 先按已装公钥严格校验
UPDATE_OK=0
if timeout "$UPDATE_TIMEOUT" apk update --no-progress >> "$LOG_FILE" 2>&1; then
    UPDATE_OK=1
    log "apk update 执行成功（签名校验通过）"
else
    UPDATE_RC=$?
    log "apk update 签名校验失败（返回码 ${UPDATE_RC}），尝试 --allow-untrusted 回退..."
    # 回退到 --allow-untrusted
    if timeout "$UPDATE_TIMEOUT" apk update --no-progress --allow-untrusted >> "$LOG_FILE" 2>&1; then
        UPDATE_OK=1
        log "apk update 执行成功（--allow-untrusted 回退模式）"
    else
        log "apk update 执行失败，返回码: $?"
    fi
fi

# 第八步：成功则打标记
if [ "$UPDATE_OK" -eq 1 ]; then
    touch "$DONE_MARK" 2>/dev/null || true
    if [ -f "$DONE_MARK" ]; then
        log "成功标记已写入: ${DONE_MARK}，后续启动将自动跳过"
    else
        log "警告: 无法写入成功标记文件，下次启动会重试"
    fi
else
    log "提示: 网络就绪后会由 hotplug 自动重试，或手动执行 apk update"
fi

# 结束日志
log "========== kenzok8 源配置脚本结束 =========="

# 第九步：确保永远返回0，不影响任何调用方
safe_exit
