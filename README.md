# Linux 网络优化与管理工具集

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

本项目致力于提供一套高效、易用的 Linux 服务器网络管理与优化脚本，涵盖端口限速、BBR 内核优化、以及常用代理服务（Hysteria2, GOST）的便捷部署。

## 📖 目录

- [包含的工具](#-包含的工具)
  - [1. 端口限速工具 (Throttle.sh)](#1-端口限速工具-throttlesh)
  - [2. BBR 网络优化脚本 (bbr.sh)](#2-bbr-网络优化脚本-bbrsh)
  - [3. Hysteria2 管理脚本 (hysteria2.sh)](#3-hysteria2-管理脚本-hysteria2sh)
  - [4. GOST 代理部署脚本 (gost-proxy.sh)](#4-gost-代理部署脚本-gost-proxysh)
- [🚀 快速开始](#-快速开始)
- [📋 系统要求](#-系统要求)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🛠️ 包含的工具

### 1. 端口限速工具 (`Throttle.sh`)

一个基于 `tc` (Traffic Control) 和 `iptables` 的精准端口限速工具，专为解决 VPS 流量滥用或带宽分配问题设计。

-   **核心功能**：
    -   **智能识别网卡**：自动识别物理网卡 (eth/ens/enp)，排除 Docker、WARP 等虚拟接口。
    -   **精准限速**：支持对特定 TCP/UDP 端口设置上传/下载速率限制（单位：MB/s）。
    -   **可视化管理**：提供实时带宽计算（Mbps）、规则列表查看、流量统计。
    -   **一键维护**：支持一键清空所有规则，自动保存配置以支持开机自启。

### 2. BBR 网络优化脚本 (`bbr.sh`)

全能型 Linux 网络优化助手，集成多种 BBR 算法与系统级参数调优。

-   **核心功能**：
    -   **内核优化**：开启 BBR，优化 TCP 窗口、缓冲区大小（默认 32MB+），提升高延迟网络下的吞吐量。
    -   **算法切换**：支持一键切换 `fq`、`fq_codel`、`fq_pie`、`cake` 等队列调度算法。
    -   **场景化优化**：针对 Hysteria2 (UDP/QUIC) 和 VLESS (TCP/WS/TLS) 提供特定的内核参数调整。
    -   **系统增强**：自动解除文件描述符限制 (Limit NOFILE)。
    -   **便捷命令**：安装后可通过 `bb` 命令快速唤醒菜单。

### 3. Hysteria2 管理脚本 (`hysteria2.sh`)

Hysteria2 服务端的一键全托管脚本。

-   **核心功能**：
    -   **生命周期管理**：一键安装、更新、卸载。
    -   **版本控制**：支持安装最新版或自定义版本。
    -   **服务托管**：通过 Systemd 管理服务，支持开机自启、状态监控与日志查看。
    -   **配置灵活**：支持自定义配置文件路径与启动参数。

### 4. GOST 代理部署脚本 (`gost-proxy.sh`)

极简的 GOST 隧道/代理服务部署工具。

-   **核心功能**：
    -   **多模式支持**：SOCKS5、HTTP、或 SOCKS5+HTTP 双协议共存。
    -   **安全认证**：支持设置用户名与密码认证。
    -   **智能检测**：部署前自动检测端口冲突。
    -   **服务守护**：自动创建 Systemd 服务配置，确保服务稳定运行。

---

## 🚀 快速开始

### 方式一：克隆仓库运行（推荐）

适合需要查看源码或批量管理脚本的用户。

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
# 运行对应脚本，例如：
./Throttle.sh
```

### 方式二：一键命令运行

直接通过网络加载并运行脚本。

#### 1. 端口限速
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/Throttle.sh)
```

#### 2. BBR 网络优化
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh)
```
> 安装后可直接输入 `bb` 命令管理。

#### 3. Hysteria2 安装
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/hysteria2.sh)
```

#### 4. GOST 代理部署
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh)
```

---

## 📋 系统要求

-   **操作系统**: 建议使用 Debian 10+, Ubuntu 20.04+, CentOS 7+ 等主流 Linux 发行版。
-   **运行权限**: 脚本涉及网络接口与内核参数修改，必须以 `root` 用户运行。
-   **基础依赖**: 脚本会自动检查并尝试安装 `curl`, `wget`, `iptables`, `iproute2`, `tar` 等基础工具。

## 🤝 贡献与反馈

欢迎提交 Issue 反馈 Bug 或建议，也欢迎提交 Pull Request 改进代码。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
