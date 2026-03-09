# Linux 网络优化与管理工具集

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

本项目提供了一套高效、易用的 Linux 服务器网络管理与优化工具集。涵盖了从端口限速、BBR 内核优化到全功能的网络方案管理（Net Tune Pro）以及代理服务部署，旨在提升服务器的网络性能与可管理性。

## 📖 目录

- [🛠️ 核心工具](#️-核心工具)
  - [1. Net Tune Pro v3 (install.sh / net-tune-pro-v3-zh.sh)](#1-net-tune-pro-v3-installsh--net-tune-pro-v3-zhsh)
  - [2. 端口限速工具 (Throttle.sh)](#2-端口限速工具-throttlesh)
  - [3. BBR 网络优化脚本 (bbr.sh)](#3-bbr-网络优化脚本-bbrsh)
  - [4. GOST 代理部署脚本 (gost-proxy.sh)](#4-gost-代理部署脚本-gost-proxysh)
  - [5. nftables 端口转发管理与 NAT 优化 (nft-forward.sh)](#5-nftables-端口转发管理与-nat-优化-nft-forwardsh)
  - [6. HTTP/SOCKS5 代理测速工具 (http-test.sh)](#6-httpsocks5-代理测速工具-http-testsh)
  - [7. 晚高峰网络诊断 (peak_test.sh)](#7-晚高峰网络诊断-peak_testsh)
- [🚀 快速开始](#-快速开始)
- [📋 系统要求](#-系统要求)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🛠️ 核心工具

### 1. Net Tune Pro v3 (`net-tune-pro-v3-zh.sh` / `install.sh`)
**推荐！最强大的全功能网络优化方案管理器。** 整合了多种预设优化方案，支持原子化配置与版本保护。现已更新至 v3.3.1，支持 Hysteria2 1G 内存极致优化。

-   **核心功能**：
    -   **12 种优化方案**：涵盖平衡、激进、UDP专项、低内存、高带宽等全场景。
    -   **BBR v3 支持**：一键安装/管理高性能 BBR v3 内核。
    -   **队列算法管理**：支持 FQ, FQ_CODEL, CAKE 等。
    -   **安全机制**：冲突检测、原子化写入、20次历史快照回滚。
    -   **一键开启 s-ui 优先级**：Nice=-10 提权，确保高负载下代理依然稳定。

### 2. 端口限速工具 (`Throttle.sh`)
基于 `tc` 和 `iptables` 的精准端口限速工具，支持物理网卡自动识别。

-   **核心功能**：支持 TCP/UDP 独立限速，实时流量统计，配置自动持久化。

### 3. BBR 网络优化脚本 (`bbr.sh`)
经典的 BBR 开启与系统内核管理工具，提供更激进的拥塞控制配置。

### 4. GOST 代理部署脚本 (`gost-proxy.sh`)
极简的 GOST 隧道部署工具，支持 SOCKS5、HTTP、SSTP 等多协议及多节点管理。

### 5. nftables 端口转发管理与 NAT 优化 (`nft-forward.sh`)
基于 `nftables` 的现代化转发工具，集成 NAT 服务器深度调优（Conntrack/ARP/BBR）。

### 6. HTTP/SOCKS5 代理测速工具 (`http-test.sh`)
命令行级代理测速，支持延迟测试与 100MB 真实下载测速，输出平均 MB/s。

### 7. 晚高峰网络诊断 (`peak_test.sh`)
专为诊断晚高峰拥塞设计，检测系统负载、网卡丢包、三网延迟及 Bufferbloat 状态。

---

## 🚀 快速开始 (一键运行)

直接复制以下命令到终端运行：

| 工具名称 | 一键运行命令 (Curl) |
| :--- | :--- |
| **Net Tune Pro v3 (全能优化)** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)` |
| **端口限速工具** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)` |
| **BBR 基础优化** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)` |
| **GOST 代理部署** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)` |
| **nftables 转发 & NAT 优化** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)` |
| **代理测速工具** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)` |
| **晚高峰网络诊断** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)` |
| **快捷安装入口 (install.sh)** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/install.sh)` |

> [!TIP]
> 运行 `net-tune-pro-v3-zh.sh` 后，可以通过菜单轻松管理系统中的所有网络配置。

---

## 💻 本地克隆运行

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
# 运行主工具
./net-tune-pro-v3-zh.sh
```

## 📋 系统要求

-   **操作系统**: Debian 10+, Ubuntu 20.04+, CentOS 7+
-   **运行权限**: 必须以 `root` 用户运行
-   **基础依赖**: 脚本会自动安装 `curl`, `wget`, `iptables`, `iproute2` 等基础工具

## 🤝 贡献与反馈

欢迎提交 Issue 或 Pull Request 来共同完善本项目。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
