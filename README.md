# Linux 网络优化与管理工具集

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

本项目提供了一套高效、易用的 Linux 服务器网络管理与优化工具集。涵盖了从端口限速、BBR 内核优化到全功能的网络方案管理（Net Tune Pro）以及代理服务部署，旨在提升服务器的网络性能与可管理性。

## 📖 目录

- [🛠️ 核心工具](#️-核心工具)
  - [1. Net Tune Pro v3 (install.sh)](#1-net-tune-pro-v3-installsh)
  - [2. 端口限速工具 (Throttle.sh)](#2-端口限速工具-throttlesh)
  - [3. BBR 网络优化脚本 (bbr.sh)](#3-bbr-网络优化脚本-bbrsh)
  - [4. GOST 代理部署脚本 (gost-proxy.sh)](#4-gost-代理部署脚本-gost-proxysh)
  - [5. NAT 专用优化脚本 (nat_optimize.sh)](#5-nat-专用优化脚本-nat_optimizesh)
  - [6. nftables 端口转发管理 (nft-forward.sh)](#6-nftables-端口转发管理-nft-forwardsh)
- [🚀 快速开始](#-快速开始)
- [📋 系统要求](#-系统要求)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🛠️ 核心工具

### 1. Net Tune Pro v3 (`install.sh`)
**推荐！最强大的全功能网络优化方案管理器。** 整合了多种预设优化方案，支持原子化配置与版本保护。

-   **核心功能**：
    -   **12 种优化方案**：
        | 方案 | 适用场景 |
        |------|----------|
        | **平衡版** | 通用推荐 (默认) |
        | **激进版** | 高并发 / 高 PPS 场景 |
        | **激进稳妥版** | 推荐的激进配置 (兼顾稳定性) |
        | **UDP 专项版** | QUIC / Hysteria2 / TUIC 优化 |
        | **流媒体代理版** | VLESS / Reality TCP 优化 |
        | **HTTP 代理版** | Squid / Nginx / Clutch 代理优化 |
        | **低内存版 (1C/1G)** | 小内存 VPS (防 OOM) |
        | **低内存版 (2C/2G)** | 中等配置 VPS |
        | **高带宽版 (1G)** | 千兆物理网卡 |
        | **高带宽版 (10G)** | 万兆物理网卡 |
        | **VPS 极致带宽版** | 虚拟网卡 (Virtio)最大化吞吐 |
        | **晚高峰抗抖动版** | **(推荐)** 解决丢包/拥塞/Bufferbloat |
    -   **BBR v3 支持**：通过集成 Joey BBR 项目，支持一键安装/管理高性能的 BBR v3 内核。
    -   **队列算法管理**：支持 FQ、FQ_CODEL、FQ_PIE、CAKE 等多种队列算法。
    -   **安全机制**：支持冲突检测、永久初始备份、历史快照记录，可随时回滚。
    -   **实时监控**：内置实时流量与网络统计查看器。
    -   **智能检测**：自动识别虚拟网卡并提供友好提示。
    -   **快照清理**：支持自动清理旧快照，保留最近 20 个。

### 2. 端口限速工具 (`Throttle.sh`)
基于 `tc` 和 `iptables` 的精准端口限速工具，专为 VPS 带宽管理设计。

-   **核心功能**：
    -   **物理网卡识别**：自动定位 eth/ens/enp 接口，完美避开 Docker、WARP 等虚拟接口。
    -   **精准双向限速**：支持针对特定 TCP/UDP 端口设置独立的上传下载速率（单位：MB/s）。
    -   **可视化统计**：实时显示命中包数与流量统计，配置自动持久化。

### 3. BBR 网络优化脚本 (`bbr.sh`)
经典的 BBR 开启与系统内核管理工具。

-   **核心功能**：
    -   **内核管理**：支持一键升级至 BBR 适配内核（Debian/Ubuntu/CentOS）。
    -   **激进模式**：针对高丢包网络优化的激进配置，配合 `fq_codel` 算法降低延迟。
    -   **一键恢复**：内置预检查机制，确保操作前系统环境符合要求。

### 4. GOST 代理部署脚本 (`gost-proxy.sh`)
极简的 GOST 隧道/代理服务 (v2.0) 部署工具。

-   **核心功能**：
    -   **多协议支持**：轻松部署 SOCKS5、HTTP 及其混合协议，**新增 SSTP VPN 支持**。
    -   **多节点管理**：支持同时运行多个独立代理节点，独立配置认证信息。
    -   **智能冲突检测**：内置端口冲突检测，防止端口占用导致服务启动失败。
    -   **流量转发**：支持 TCP/UDP 端口转发配置。
    -   **自动守护**：自动配置 Systemd 服务，确保代理进程稳定在线。

### 5. NAT 专用优化脚本 (`nat_optimize.sh`)
专为 NAT 转发服务器设计的深度优化工具，特别适配 **LXC/Docker 容器环境**。

-   **核心功能**：
    -   **容器友好**：自动识别虚拟化环境，兼容只读内核参数，LXC/Proxmox 下稳定运行。
    -   **智能连接跟踪**：根据内存自动计算 `nf_conntrack_max`，防止高并发丢包。
    -   **激进连接回收**：缩短 TCP/UDP 超时时间，加速连接表释放，适合大量短连接场景。
    -   **BBR/队列优化**：自动启用 BBR + FQ，优化 UDP 缓冲区以支持 QUIC/Hysteria。
    -   **网卡/系统调优**：自动调整 Ring Buffer、启用多队列 RSS、安装 irqbalance 及提升文件描述符限制。

### 6. nftables 端口转发管理 (`nft-forward.sh`)
基于 `nftables` 的端口转发管理工具，提供现代化的转发方案，支持持久化。

-   **核心功能**：
    -   **表隔离**：使用专用 `nftables` 表管理，不影响系统其他网络规则。
    -   **协议支持**：同时支持 TCP 和 UDP 的端口转发。
    -   **规则持久化**：自动保存规则至标准路径，确保重启不丢失。
    -   **易用菜单**：提供添加、查看、删除、重载等交互式管理菜单。
    -   **环境自检**：自动检测并配置内核转发与必要工具。

---

## 🚀 快速开始

### 方式一：克隆仓库运行（推荐）

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
# 运行 Net Tune Pro v3 (推荐)
./install.sh
```

### 方式二：一键命令运行

#### 1. Net Tune Pro v3 (全能优化方案 - 推荐)
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/install.sh)
```

#### 2. 端口限速
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/Throttle.sh)
```

#### 3. BBR 基础优化
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh)
```

#### 4. GOST 代理部署
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh)
```

#### 5. NAT 专用优化 (LXC/容器推荐)
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/nat_optimize.sh)
```

#### 6. nftables 端口转发
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/nft-forward.sh)
```

---

## 🛠️ 诊断工具

### 晚高峰网络诊断 (`peak_test.sh`)
专为诊断晚高峰时段网络拥塞、丢包和延迟抖动设计。

-   **功能**：
    -   系统负载与网卡丢包检测
    -   关键节点 Ping 测试 (阿里云/腾讯云/Cloudflare/Google)
    -   路由跳数简易测试

**使用方法**：
```bash
# 下载并运行
wget -O peak_test.sh https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh && chmod +x peak_test.sh && ./peak_test.sh
```

---


## 📋 系统要求

-   **操作系统**: Debian 10+, Ubuntu 20.04+, CentOS 7+
-   **运行权限**: 必须以 `root` 用户运行
-   **基础依赖**: 脚本会自动安装 `curl`, `wget`, `iptables`, `iproute2` 等基础工具

## 🤝 贡献与反馈

欢迎提交 Issue 或 Pull Request 来共同完善本项目。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
