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
  - [5. nftables Port Forwarding & NAT Optimization (nft-forward.sh)](#5-nftables-port-forwarding--nat-optimization-nft-forwardsh)
- [🚀 Quick Start](#-quick-start)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🛠️ Core Tools

### 1. Net Tune Pro v3 (`install.sh`)
**Recommended! The most powerful all-in-one network optimization profile manager.** Integrates various preset optimization plans with atomic configuration and version protection.

-   **Key Features**:
    -   **12 Optimization Profiles**:
        | Profile | Use Case |
        |---------|----------|
        | **Balanced** | General purpose (Recommended) |
        | **Aggressive** | High Concurrency / High PPS |
        | **Aggressive Safe** | Balanced Aggressive (Stable) |
        | **UDP/QUIC** | QUIC / Hysteria2 / TUIC Optimization |
        | **Streaming** | VLESS / Reality TCP Optimization |
        | **HTTP Proxy** | Squid / Nginx / Clutch Proxy Optimization |
        | **Low Memory (1C/1G)** | Small RAM VPS (Prevent OOM) |
        | **Low Memory (2C/2G)** | Medium RAM VPS |
        | **High Bandwidth (1G)** | 1Gbps Physical NIC |
        | **High Bandwidth (10G)** | 10Gbps Physical NIC |
        | **VPS Max Bandwidth** | Virtual NIC Max Throughput |
        | **Anti-Bufferbloat** | **(Recommended)** Fix Packet Loss/Lag |
    -   **BBR v3 Support**: Integrated Joey BBR project for one-click installation and management of high-performance BBR v3 kernels.
    -   **Queue Algorithm Management**: Supports FQ, FQ_CODEL, FQ_PIE, CAKE and more queue algorithms.
    -   **Security Mechanism**: Features conflict detection, permanent pristine backup, and history snapshots for easy rollback.
    -   **Real-time Monitoring**: Built-in real-time traffic and network statistics viewer.
    -   **Smart Detection**: Automatically identifies virtual NICs and provides friendly prompts.
    -   **Snapshot Cleanup**: Supports automatic cleanup of old snapshots, keeping the latest 20.

### 2. Port Throttle Tool (`Throttle.sh`)
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
    -   **Traffic Forwarding**: Supports TCP/UDP port forwarding configuration.
    -   **Automatic Daemon**: Automatically configures Systemd services to ensure the proxy process stays online.

### 5. nftables Port Forwarding & NAT Optimization (`nft-forward.sh`)
**Recommended!** A modernized port forwarding tool based on `nftables`, now integrated with **NAT Server Depth Optimization**.

-   **Key Features**:
    -   **Two-in-One Design**: Supports interactive addition/deletion of forwarding rules while providing one-click NAT network tuning.
    -   **Smart Network Tuning**: Built-in `nat_optimize` logic for LXC/Docker environments, optimizing connection tracking (`nf_conntrack`), ARP cache, BBR control, and UDP buffers.
    -   **Table Isolation & Persistence**: Uses a dedicated `nftables` table ensuring no interference with other rules, with automatic rule persistence.
    -   **Precise Control**: Supports Source IP whitelisting, interface binding, and protocol separation (TCP/UDP/Both).
    -   **Easy Operation**: Fully interactive menu with automatic kernel forwarding and dependency configuration.

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

#### 2. Port Throttling
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

#### 5. nftables Port Forwarding & NAT Optimization (Recommended)
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/nft-forward.sh)
```

---

## 📋 System Requirements

-   **OS**: Debian 10+, Ubuntu 20.04+, CentOS 7+
-   **Permissions**: Must be run as `root`
-   **Dependencies**: Automatically installs base tools like `curl`, `wget`, `iptables`, `iproute2`

## 🤝 Contributing

Issues for bug reports or suggestions are welcome. Pull Requests to improve the toolkit are appreciated.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
