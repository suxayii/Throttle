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
- [🚀 快速开始](#-快速开始)
- [📋 系统要求](#-系统要求)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🛠️ 核心工具

### 1. Net Tune Pro v3 (`install.sh`)
**最强大的全功能网络优化方案管理器。** 整合了多种预设优化方案，支持原子化配置与版本保护。

-   **核心功能**：
    -   **多方案切换**：内置均衡型 (Balanced)、激进型 (Aggressive)、Xray/Hysteria2 专用方案、低配机器专用方案 (1C1G/2C2G) 等。
    -   **BBR v3 支持**：通过集成 Joey BBR 项目，支持一键安装/管理高性能的 BBR v3 内核。
    -   **安全机制**：支持冲突检测、永久初始备份、历史快照记录，可随时回滚到上一个应用点。
    -   **实时监控**：内置实时流量与网络统计查看器。

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
    -   **多协议支持**：轻松部署 SOCKS5、HTTP 及其混合协议。
    -   **多节点管理**：支持同时运行多个独立代理节点，独立配置认证信息。
    -   **自动守护**：自动配置 Systemd 服务，确保代理进程稳定在线。

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

#### 1. Net Tune Pro v3 (全能优化方案)
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

---

## 📋 系统要求

-   **操作系统**: Debian 10+, Ubuntu 20.04+, CentOS 7+。
-   **运行权限**: 必须以 `root` 用户运行。
-   **基础依赖**: 脚本会自动安装 `curl`, `wget`, `iptables`, `iproute2` 等基础工具。

## 🤝 贡献与反馈

欢迎提交 Issue 或 Pull Request 来共同完善本项目。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
