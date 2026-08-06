#!/bin/sh
# ============================================================
# kenzok8 第三方插件源自动配置主脚本（apk 版）
#
# 功能：自动检测系统架构，添加 kenzok8/dllkids 二进制源并更新包列表
# 设计原则：
#   1. 幂等安全：已执行成功则直接退出，重复执行无副作用
#   2. 容错兜底：所有异常全部捕获，永远不抛错影响系统
#   3. 可追溯：日志输出到 /tmp，重启自动清理不占闪存
#   4. 架构降级：精确架构失败后自动降级到通用架构
#   5. 可禁用：删除 /etc/kenzok8.done 可重新触发，删除脚本即可完全移除
#
# 适用：OpenWrt 25.12+ (apk 包管理器)
# 源地址：https://down.dllkids.xyz/openwrt-feed/25.12/
# ============================================================

# -------------------------- 配置区 --------------------------
# 成功标记文件（持久化，成功一次永久生效）
DONE_MARK="/etc/kenzok8.done"
# 源配置文件（单独文件，不混入系统默认源）
REPO_FILE="/etc/apk/repositories.d/kenzok8.list"
# 日志文件（临时目录，重启自动清理）
LOG_FILE="/tmp/kenzok8.log"
# 源基础地址
BASE_URL="https://down.dllkids.xyz/openwrt-feed"
# SDK 版本
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
# 去重，按优先级排序
candidate_arches() {
    requested_arch="$1"
    _seen=""
    _add() {
        case "$_seen" in
            *"|$1|"*) return ;;
        esac
        _seen="${_seen}|$1|"
        echo "$1"
    }
    # 1. 精确架构
    _add "$requested_arch"
    # 2. aarch64 系列降级到 aarch64_generic
    case "$requested_arch" in
        aarch64|arm64|aarch64_*)
            _add "aarch64_generic"
            ;;
    esac
    # 3. all 架构（通用包）
    _add "all"
}

# 尝试用指定架构配置源并执行 apk update
# 返回 0 成功，1 失败
try_arch() {
    try_arch_name="$1"
    arch_url="${BASE_URL}/${SDK}/${try_arch_name}"

    log "尝试架构: ${try_arch_name} (${arch_url})"

    # 第一步：写入源配置文件
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
        echo "# 架构: ${try_arch_name}"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "${arch_url}/packages.adb"
    } > "$REPO_FILE" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "  错误: 源配置写入失败"
        return 1
    fi
    log "  源配置写入成功: ${REPO_FILE}"

    # 第二步：下载并安装 ECDSA PEM 公钥
    mkdir -p /etc/apk/keys 2>/dev/null || true
    if [ ! -f "$KEY_FILE" ]; then
        log "  正在下载 ECDSA 公钥: ${KEY_URL}"
        if fetch_file "$KEY_URL" "$KEY_FILE"; then
            chmod 644 "$KEY_FILE" 2>/dev/null || true
            log "  公钥安装成功: ${KEY_FILE}"
        else
            log "  警告: 公钥下载失败，将使用 --allow-untrusted 模式"
        fi
    else
        log "  公钥已存在，跳过下载"
    fi

    # 第三步：执行 apk update（不使用 timeout，避免嵌入式环境无 timeout 命令）
    log "  开始执行 apk update..."

    UPDATE_OK=0
    # 先按已装公钥严格校验
    if apk update --no-progress >> "$LOG_FILE" 2>&1; then
        UPDATE_OK=1
        log "  apk update 执行成功（签名校验通过）"
    else
        UPDATE_RC=$?
        log "  apk update 签名校验失败（返回码 ${UPDATE_RC}），尝试 --allow-untrusted 回退..."
        # 回退到 --allow-untrusted
        if apk update --no-progress --allow-untrusted >> "$LOG_FILE" 2>&1; then
            UPDATE_OK=1
            log "  apk update 执行成功（--allow-untrusted 回退模式）"
        else
            log "  apk update 执行失败，返回码: $?"
        fi
    fi

    if [ "$UPDATE_OK" -eq 1 ]; then
        return 0
    else
        return 1
    fi
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

# 第四步：按优先级逐个尝试架构（精确 → 通用 → all）
SUCCESS=0
SELECTED_ARCH=""
for candidate in $(candidate_arches "$ARCH"); do
    if try_arch "$candidate"; then
        SUCCESS=1
        SELECTED_ARCH="$candidate"
        break
    fi
    log "  架构 ${candidate} 失败，尝试下一个..."
done

# 第五步：成功则打标记
if [ "$SUCCESS" -eq 1 ]; then
    log "最终选用架构: ${SELECTED_ARCH}"
    touch "$DONE_MARK" 2>/dev/null || true
    if [ -f "$DONE_MARK" ]; then
        log "成功标记已写入: ${DONE_MARK}，后续启动将自动跳过"
    else
        log "警告: 无法写入成功标记文件，下次启动会重试"
    fi
else
    log "错误: 所有候选架构均失败"
    log "提示: 网络就绪后会由 hotplug / init.d 自动重试，或手动执行 apk update"
fi

# 结束日志
log "========== kenzok8 源配置脚本结束 =========="

# 第六步：确保永远返回0，不影响任何调用方
safe_exit
