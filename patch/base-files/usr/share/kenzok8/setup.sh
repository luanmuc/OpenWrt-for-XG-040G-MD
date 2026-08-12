#!/bin/sh
# kenzok8 第三方源配置脚本
# 直接调用官方 setup 脚本，自动检测架构、安装公钥、配置源

LOG_FILE="/tmp/kenzok8.log"
DONE_MARK="/etc/kenzok8.done"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 已经成功配置过则直接退出（幂等）
if [ -f "$DONE_MARK" ]; then
    exit 0
fi

log "开始配置 kenzok8 第三方源..."

# 检查网络
if ! ping -c 1 -W 2 down.dllkids.xyz > /dev/null 2>&1; then
    log "网络不通，稍后重试"
    exit 0
fi

# 调用官方 setup 脚本
if wget -qO- https://down.dllkids.xyz/openwrt-feed/openwrt-feed-setup.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
    # 标记成功
    touch "$DONE_MARK"
    log "kenzok8 源配置成功"
else
    log "kenzok8 源配置失败，下次重试"
fi

exit 0
