# Linux Network Optimization and Management Toolkit

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

This project provides a set of efficient, easy-to-use Linux server network management and optimization tools. It covers everything from port throttling and BBR kernel optimization to full-featured network profile management (Net Tune Pro) and proxy service deployment, designed to enhance server network performance and manageability.

## 📖 Table of Contents

- [🛠️ Core Tools](#️-core-tools)
  - [1. Net Tune Pro v3 (install.sh)](#1-net-tune-pro-v3-installsh)
  - [2. Port Throttle Tool (Throttle.sh)](#2-port-throttle-tool-throttlesh)
  - [3. BBR Optimization Script (bbr.sh)](#3-bbr-optimization-script-bbrsh)
  - [4. GOST Proxy Script (gost-proxy.sh)](#4-gost-proxy-script-gost-proxysh)
- [🚀 Quick Start](#-quick-start)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🛠️ Core Tools

### 1. Net Tune Pro v3 (`install.sh`)
**Recommended! The most powerful all-in-one network optimization profile manager.** Integrates various preset optimization plans with atomic configuration and version protection.

-   **Key Features**:
    -   **Multi-Profile Support**: Built-in Balanced, Aggressive, Xray/Hysteria2 dedicated, and Low-resource (1C1G/2C2G) profiles.
    -   **BBR v3 Support**: Integrated Joey BBR project for one-click installation and management of high-performance BBR v3 kernels.
    -   **Security Mechanism**: Features conflict detection, permanent pristine backup, and history snapshots for easy rollback to previous application points.
    -   **Real-time Monitoring**: Built-in real-time traffic and network statistics viewer.

### 2. Net Tune Pro v2.1 (`bbr2.sh`)
**Classic version of Net Tune Pro.** Provides stable network optimization plans, ideal as an alternative for specific kernel environments.

-   **Key Features**:
    -   Covers basic BBR enabling and system parameter tuning.
    -   Supports various preset Profiles for different network scenarios.

### 3. Port Throttle Tool (`Throttle.sh`)
A precise port throttling tool based on `tc` and `iptables`, designed specifically for VPS bandwidth management.

-   **Key Features**:
    -   **Physical Interface Detection**: Automatically identifies eth/ens/enp interfaces, perfectly avoiding virtual interfaces like Docker or WARP.
    -   **Precise Bi-directional Throttling**: Supports independent upload/download rate limiting for specific TCP/UDP ports (Unit: MB/s).
    -   **Visual Statistics**: Displays real-time packet hits and traffic statistics with automatic configuration persistence.

### 3. BBR Optimization Script (`bbr.sh`)
A classic tool for BBR enabling and system kernel management.

-   **Key Features**:
    -   **Kernel Management**: One-click upgrade to BBR-compatible kernels for Debian, Ubuntu, and CentOS.
    -   **Aggressive Mode**: Aggressive configurations optimized for high-loss networks, utilizing the `fq_codel` algorithm to reduce latency.
    -   **One-Click Restore**: Built-in pre-check mechanism to ensure the system environment meets requirements before operation.

### 4. GOST Proxy Script (`gost-proxy.sh`)
A minimalist deployment tool for GOST tunnel/proxy services (v2.0).

-   **Key Features**:
    -   **Multi-Protocol Support**: Easily deploy SOCKS5, HTTP, and hybrid protocols.
    -   **Multi-Node Management**: Supports running multiple independent proxy nodes simultaneously with separate authentication settings.
    -   **Automatic Daemon**: Automatically configures Systemd services to ensure the proxy process stays online.

---

## 🚀 Quick Start

### Method 1: Clone and Run (Recommended)

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
# Run Net Tune Pro v3 (Recommended)
./install.sh
```

### Method 2: One-Click Command

#### 1. Net Tune Pro v3 (All-in-one Optimization - Recommended)
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/install.sh)
```

#### 2. Net Tune Pro v2.1 (Classic Optimization Plan)
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr2.sh)
```

#### 3. Port Throttling
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/Throttle.sh)
```

#### 3. BBR Basic Optimization
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh)
```

#### 4. GOST Proxy Deployment
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh)
```

---

## 📋 System Requirements

-   **OS**: Debian 10+, Ubuntu 20.04+, CentOS 7+.
-   **Permissions**: Must be run as `root`.
-   **Dependencies**: Automatically installs base tools like `curl`, `wget`, `iptables`, `iproute2`.

## 🤝 Contributing

Issues for bug reports or suggestions are welcome. Pull Requests to improve the toolkit are appreciated.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
