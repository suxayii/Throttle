# ⚡ Linux 网络优化与管理工具集 (Throttle)

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License&color=blue)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Size&color=brightgreen)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?color=orange)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

本项目提供了一套**高性能、工业级**的 Linux 服务器网络管理与优化工具集。从内核级的 BBR 调优到应用层的流量管控，全方位榨干服务器网络性能，特别针对跨境、晚高峰及低资源环境进行了深度适配。

---

## 📖 目录

- [🚀 快速开始 (一键运行)](#-快速开始-一键运行)
- [🛠️ 核心工具介绍](#️-核心工具介绍)
- [📋 系统要求](#-系统要求)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🚀 快速开始 (一键运行)

> [!TIP]
> **提示**：鼠标悬停在下方代码块右上角，即可看到 GitHub 提供的一键复制按钮。

### 💎 主力工具 (全能网络优化)

**Net Tune Pro v3 (全能优化 - 强烈推荐)**
*整合 12 种优化方案，支持 BBR v3 安装、s-ui 优先级设置、原子化配置保护。*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)
```

### 🛠️ 专项管理工具

**1. 端口限速工具 (`tc` + `iptables` 精准流控)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)
```

**2. BBR 优化脚本 (内核级加速与内核管理)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)
```

**3. GOST 代理部署 (极简多协议隧道部署)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)
```

**4. 转发 & NAT 调优 (基于 `nftables` 的现代化转发)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)
```

**5. 代理测速工具 (下载测速与连通性诊断)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)
```

**6. 晚高峰网络诊断 (丢包/抖动/QoS 实时分析)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)
```

**7. s-ui 极致优先级提权 (Nice -20 & FIFO 90)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/s-20.sh)
```

**8. 快捷安装入口 (`install.sh`)**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/install.sh)
```

---

## 🛠️ 核心工具介绍

### 🔥 1. Net Tune Pro v3 (`net-tune-pro-v3-zh.sh`)
**最强大的 Linux 网络“手术刀”**。
- **智能化**：自动识别虚拟化架构（KVM/LXC/Docker）与网卡类型。
- **场景化**：预设 12 种 Profile（平衡、激进、Hysteria2 专项、1C1G 低内存等）。
- **版本化**：支持 20 次快照回滚，修改前自动备份，哪怕改坏了也能一键恢复。
- **服务优化**：集成 s-ui 优先级调节，确保在 CPU 100% 时代理服务依然丝滑。

### 🚥 2. 端口限速工具 (`Throttle.sh`)
专为 VPS 流量计费设计，精准控制单个端口的上下行带宽。
- **避坑逻辑**：自动绕过 Docker/WARP 等虚拟网卡，直击物理网卡。
- **实时性**：自带流量统计波动查看。

### 🚀 3. s-ui 极致优先级 (`s-20.sh`)
**针对 Hysteria2 / VLESS 的黑科技优化**。
- 将代理进程推送到系统最高优先级 (`Nice -20`)。
- 开启 `FIFO` 实时调度，降低进程上下文切换损耗，极致压榨单核 PPS。

### 🌍 4. nftables 转发与 NAT 调优 (`nft-forward.sh`)
结合了 `nftables` 的现代转发管理与 NAT 性能优化（优化连接跟踪、ARP 表等）。

---

## 📋 系统要求

- **操作系统**: Debian 10+, Ubuntu 18.04+, CentOS 7+
- **架构**: x86_64, ARM64 (部分脚本支持)
- **权限**: 必须以 `root` 用户运行

> [!IMPORTANT]
> 执行任何优化前，建议先通过 `install.sh` 进行初始备份。

## 🤝 贡献与反馈

如果您觉得好用，欢迎点一个 **Star** ⭐️。
有问题请提交 [Issue](https://github.com/suxayii/Throttle/issues)。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
