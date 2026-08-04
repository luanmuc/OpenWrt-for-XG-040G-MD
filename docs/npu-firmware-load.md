# XG-040G-MD (AN7581) NPU 固件加载报错分析与修复记录

## 现象

启动日志中出现 NPU 固件加载失败（`-2` 通常对应 `ENOENT`）：

```text
airoha-npu 1e900000.npu: Direct firmware load for airoha/en7581_npu_rv32.bin failed with error -2
```

同时，在系统里可能已经能看到固件包“已安装”，并且固件文件确实存在（例如在只读的 `/rom/lib/firmware/...`）。

## 现场确认点

1. 系统是 SNAPSHOT，包管理器为 `apk`（不是 `opkg`），因此“已安装/存在于 rootfs”并不必然代表“驱动 probe 时就能读到文件”。
2. 固件文件存在位置通常为：
   - `/rom/lib/firmware/airoha/en7581_npu_rv32.bin` (squashfs 只读根)
   - 或者 `/lib/firmware/airoha/en7581_npu_rv32.bin` (overlay)

## 根因判断

在该平台上，NPU/以太网相关驱动如果是 **内建（built-in）**，可能在系统早期就 probe 并调用 `request_firmware()`。

OpenWrt 通常关闭了 firmware loader 的 user-helper fallback（安全考虑），例如：

```text
# CONFIG_FW_LOADER_USER_HELPER is not set
# CONFIG_FW_LOADER_USER_HELPER_FALLBACK is not set
```

在“驱动 probe 的时间点”如果 rootfs/firmware 路径还未就绪，`request_firmware()` 会直接返回 `-2`，从而产生上述报错；即便后续 rootfs 挂载完成，驱动也未必会自动重试加载。

结论：这不是“固件包没装/文件不存在”的单一问题，更像是 **probe 时机过早 + 无 user-helper fallback + 固件在 rootfs 上** 的组合问题。

## 修复方案选择

可选方向（按推荐顺序）：

1. 推荐：将相关驱动改为 **kmod 模块**，由 OpenWrt 在系统起来后自动加载，确保固件路径可用。
2. 不推荐：开启 `FW_LOADER_USER_HELPER(_FALLBACK)` 或引入用户态 helper（有安全/策略因素，OpenWrt 上游通常不接受）。
3. 其它：把固件塞进 initramfs 或驱动内置固件（维护成本更高）。

本项目采用方案 1。

## 已做修改（Fork 分支）

修改发生在用户 fork：`xiangtailiang/openwrt` 分支 `xg040gmd-fixes`。

### 1) 确保镜像带上 NPU 固件包，并去掉无意义的 AFE 报错

目的：
- 让 `airoha/en7581_npu_rv32.bin` 被打进镜像（rootfs）
- `an7581-audio ... probe ... -2` 属于无用噪声时，直接禁用该板级的 AFE 节点

对应提交：
- `ebcb80714c` `airoha: an7581: bell xg-040g-md: add NPU firmware, disable AFE`

关键改动点（文件级）：
- `target/linux/airoha/image/an7581.mk`: `Device/bell_xg-040g-md` 增加 `DEVICE_PACKAGES += airoha-en7581-npu-firmware`
- `target/linux/airoha/dts/an7581-bell_xg-040g-md.dts`: 增加 `&afe { status = "disabled"; };`

### 2) 将 Airoha ETH/NPU 驱动改为 kmod，避免早期 probe 读不到固件

目的：
- 将 `CONFIG_NET_AIROHA*` 从内建改为模块
- 引入 `kmod-airoha-npu` / `kmod-airoha-eth`，并设置 autoload，让系统起来后自动加载
- 默认将上述 kmod 加入该 target 的默认包

对应提交：
- `7c9ed7ad41` `airoha: an7581: ship airoha-eth/npu as kmods`

关键改动点（文件级）：
- `target/linux/airoha/an7581/config-6.12`:
  - `CONFIG_NET_AIROHA=m`
  - `CONFIG_NET_AIROHA_NPU=m`
- `package/kernel/linux/modules/netdevices.mk`:
  - 新增 `KernelPackage/airoha-npu` -> `kmod-airoha-npu`（autoload 优先级 18）
  - 新增 `KernelPackage/airoha-eth` -> `kmod-airoha-eth`（autoload 优先级 19，依赖 `+kmod-airoha-npu`）
- `target/linux/airoha/an7581/target.mk`:
  - 默认包加入 `kmod-airoha-eth kmod-airoha-npu`（以及已有的固件包）

## 验证方法（刷机后）

在设备上确认固件存在、模块加载、以及 dmesg 不再出现 `-2`：

```sh
# 固件文件
ls -l /rom/lib/firmware/airoha/en7581_npu_rv32.bin 2>/dev/null || true
ls -l /lib/firmware/airoha/en7581_npu_rv32.bin 2>/dev/null || true

# 模块是否加载
lsmod | grep -E 'airoha|npu' || true

# 观察启动日志
dmesg | grep -nE 'airoha-npu|en7581_npu' || true
```

如果需要手动触发一次重新 probe（调试用）：

```sh
echo 1e900000.npu > /sys/bus/platform/drivers/airoha-npu/unbind
sleep 1
echo 1e900000.npu > /sys/bus/platform/drivers/airoha-npu/bind
dmesg | tail -n 80
```

## 备注

- “LuCI 显示已安装固件包”只说明 rootfs 里有该文件，不保证驱动 probe 的那个时刻文件系统已经就绪。
- 本文档只覆盖 NPU 固件加载报错与修复；NAT 性能/CPU 打满（IRQ/RPS/flow offload 等）属于另一条排查线索。

