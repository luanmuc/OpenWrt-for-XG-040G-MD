# OpenWrt for XG-040G-MD

专为 **NOKIA BELL XG-040G-MD** 路由器定制的 OpenWrt 固件项目。
基于 [xiangtailiang/openwrt](https://github.com/xiangtailiang/openwrt) 源码构建，提供双分支并行维护，追求稳定、精简与易用。

---

## 📋 项目简介

| 项目 | 说明 |
|------|------|
| **适配设备** | NOKIA BELL XG-040G-MD |
| **主控芯片** | Airoha AN7581 |
| **固件基础** | OpenWrt |
| **构建方式** | GitHub Actions 全自动编译 |
| **发布周期** | 每周一 00:00 定时构建 |

---

## 🌿 分支说明

本项目维护两个并行分支，满足不同使用需求：

### OpenWrt Main 分支
- **内核版本**：6.18.x
- **特点**：基于 OpenWrt main (snapshot)，紧跟上游最新开发
- **适用**：喜欢尝鲜、关注新特性的用户

### OpenWrt 25.12 分支
- **内核版本**：6.12.x
- **特点**：基于 OpenWrt 25.12 稳定版，经过充分测试
- **适用**：追求稳定性的生产环境用户

---

## 🔧 硬件参数

| 项目 | 参数 |
|------|------|
| **SoC** | Airoha AN7581 |
| **CPU** | 四核 ARM Cortex-A53 @ 1.0GHz |
| **内存** | 512MB DDR3（可用约 510MB） |
| **闪存** | 256MB SPI NAND |
| **网络接口** | 1× 2.5G 电口（WAN/eth1）、3× 千兆电口（LAN）、1× XG-PON 光口 |
| **其他接口** | 1× USB 3.0 |

---

## ✨ 固件特性

### 核心优化
- ✅ **SkyHigh 闪存完美适配**：采用官方 Robust Read Workaround 补丁，运行稳定不掉线
- 🎯 **精简定制**：剔除冗余组件，保留核心功能，资源占用低
- 🚀 **两级编译机制**：多线程编译失败自动降级单线程详细编译，提高构建成功率
- 📊 **Release 有序发布**：Tag 带数字序号前缀，固定发布页显示顺序

### 预装插件

**界面与语言**
- LuCI Web 管理界面（支持 HTTPS）
- 完整中文语言包，开箱即用
- Argon 现代化主题（默认）+ Bootstrap 原生主题（可切换）

**网络与扩展**
- HomeProxy 代理客户端（sing-box 后端）
- iStore 易有云软件商店
- OpenAppFilter 应用过滤
- kenzok8 第三方软件源

**系统工具**
- watchcat 硬件看门狗守护
- MAC 地址修复
- ttyd 网页终端
- 文件传输与文件管理器
- 自定义命令快捷执行
- darkstat 流量统计分析

---

## ⚙️ 默认配置

| 项目 | 默认值 |
|------|--------|
| **管理地址** | `http://192.168.1.1` |
| **用户名** | `root` |
| **密码** | 无（首次登录请设置） |
| **WAN 口** | 2.5G 网口（最左侧） |
| **LAN 口** | 3× 1G 网口 |
| **DHCP** | 自动开启，网段 `192.168.1.0/24` |

---

## 🔨 编译说明

本项目通过 **GitHub Actions** 实现全自动构建：

### 触发方式
- **定时构建**：每周一 00:00（北京时间）自动触发全部分支编译
- **手动触发**：通过 GitHub Actions 页面手动选择分支构建
- **推送触发**：代码推送时自动触发对应分支构建

### 构建产物
所有固件在 **Release** 页面发布，包含：
- `factory` 固件 — 原厂系统首次刷入
- `sysupgrade` 固件 — OpenWrt 系统内升级
- `sha256sums` 校验文件

### 构建流程
1. 同步上游 OpenWrt 源码
2. 应用设备适配补丁与优化配置
3. 动态集成 iStore 官方 feed 源与 kenzok8 第三方源
4. 多线程并行编译（失败自动降级单线程）
5. 打包发布至 Release

---

## 🙏 致谢

- [xiangtailiang/openwrt](https://github.com/xiangtailiang/openwrt) — 设备适配基础源码
- [OpenWrt](https://github.com/openwrt/openwrt) — OpenWrt 官方上游
- [iStore](https://github.com/istoreos) — 易有云软件商店
- [kenzok8/openwrt-packages](https://github.com/kenzok8/openwrt-packages) — 第三方软件源
- 所有为 OpenWrt 生态贡献代码的开发者

---

## ⚠️ 免责声明

本项目仅供学习研究使用，请遵守当地法律法规，请勿用于非法用途。使用本固件所产生的一切后果由使用者自行承担。
