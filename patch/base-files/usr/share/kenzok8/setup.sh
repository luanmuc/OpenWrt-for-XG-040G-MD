#!/bin/sh
# ============================================================
# kenzok8 第三方插件源自动配置主脚本
# 
# 功能：自动检测系统架构，添加kenzok8二进制源并更新包列表
# 设计原则：
#   1. 幂等安全：已执行成功则直接退出，重复执行无副作用
#   2. 容错兜底：所有异常全部捕获，永远不抛错影响系统
#   3. 可追溯：日志输出到 /tmp，重启自动清理不占闪存
#   4. 可禁用：删除 /etc/kenzok8.done 可重新触发，删除脚本即可完全移除
#
# 适用：OpenWrt 25.12+ (apk包管理器)
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
BASE_URL="https://op.dllkids.xyz/packages"

# -------------------------- 函数区 --------------------------
# 日志输出函数：统一格式，带时间戳
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# 安全退出函数：确保永远返回0
safe_exit() {
    exit 0
}

# -------------------------- 主逻辑 --------------------------
# 第一步：幂等检查 - 已成功配置过则直接退出
if [ -f "$DONE_MARK" ]; then
    # 已完成，静默退出，不写日志避免刷屏
    safe_exit
fi

# 初始化日志目录（确保/tmp存在，正常都存在，兜底用）
mkdir -p /tmp 2>/dev/null || true

# 记录启动日志
log "========== kenzok8 源配置脚本启动 =========="

# 第二步：读取系统架构信息
# 从 /etc/openwrt_release 读取 DISTRIB_ARCH 变量
# 两个分支（main/25.12）都有这个文件和变量
if [ -f /etc/openwrt_release ]; then
    # source 加载系统版本信息
    . /etc/openwrt_release 2>/dev/null || true
    ARCH="${DISTRIB_ARCH}"
    log "检测到系统架构: ${ARCH}"
    log "系统版本: ${DISTRIB_DESCRIPTION:-unknown}"
else
    log "错误: 未找到 /etc/openwrt_release 文件，无法获取架构"
    safe_exit
fi

# 架构为空则退出
if [ -z "$ARCH" ]; then
    log "错误: 无法获取系统架构 (DISTRIB_ARCH 为空)"
    safe_exit
fi

# 第三步：拼接完整源地址
FEED_URL="${BASE_URL}/${ARCH}/"
log "源地址: ${FEED_URL}"

# 第四步：确保 repositories.d 目录存在
# 三个分支默认都有这个目录，这里做兜底
mkdir -p /etc/apk/repositories.d 2>/dev/null || true

# 第五步：写入源配置文件（单独文件）
# 先检查是否已经写过（虽然有done标记兜底，但双重保险）
if grep -q "dllkids.xyz" "$REPO_FILE" 2>/dev/null; then
    log "源配置已存在，跳过写入"
else
    # 写入配置，带注释说明
    {
        echo "# kenzok8 第三方插件源 - 自动配置"
        echo "# 架构: ${ARCH}"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "${FEED_URL}"
    } > "$REPO_FILE" 2>/dev/null

    if [ $? -eq 0 ]; then
        log "源配置文件写入成功: ${REPO_FILE}"
    else
        log "错误: 源配置文件写入失败"
        safe_exit
    fi
fi

# 第六步：执行 apk update 更新包列表
# 使用 timeout 限制执行时间，网络不好时不会卡死
log "开始执行 apk update（超时 ${UPDATE_TIMEOUT}秒）..."
# 执行更新，所有输出重定向到日志
timeout "$UPDATE_TIMEOUT" apk update --no-progress >> "$LOG_FILE" 2>&1
UPDATE_RESULT=$?

if [ "$UPDATE_RESULT" -eq 0 ]; then
    # 更新成功
    log "apk update 执行成功"

    # 第七步：标记完成（持久化）
    touch "$DONE_MARK" 2>/dev/null || true

    if [ -f "$DONE_MARK" ]; then
        log "成功标记已写入: ${DONE_MARK}，后续启动将自动跳过"
    else
        log "警告: 无法写入成功标记文件，下次启动会重试"
    fi
else
    # 更新失败
    if [ "$UPDATE_RESULT" -eq 124 ]; then
        log "apk update 超时（${UPDATE_TIMEOUT}秒），网络可能未就绪"
    else
        log "apk update 执行失败，返回码: ${UPDATE_RESULT}"
    fi
    log "提示: 网络就绪后会由 hotplug 自动重试，或手动执行 apk update"
fi

# 结束日志
log "========== kenzok8 源配置脚本结束 =========="

# 第八步：确保永远返回0，不影响任何调用方
safe_exit
