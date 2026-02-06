# Linux Network Optimization and Management Toolkit

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

This project provides a set of efficient and easy-to-use Linux server network management and optimization scripts, covering port throttling, BBR kernel optimization, and convenient deployment of common proxy services (GOST).

## 📖 Table of Contents

- [Included Tools](#-included-tools)
  - [1. Port Throttle Tool (Throttle.sh)](#1-port-throttle-tool-throttlesh)
  - [2. BBR Optimization Script (bbr.sh)](#2-bbr-optimization-script-bbrsh)
  - [3. GOST Proxy Script (gost-proxy.sh)](#3-gost-proxy-script-gost-proxysh)
- [🚀 Quick Start](#-quick-start)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🛠️ Included Tools

### 1. Port Throttle Tool (`Throttle.sh`)

A precise port throttling tool based on `tc` (Traffic Control) and `iptables`, designed to solve VPS traffic abuse or bandwidth allocation issues.

-   **Key Features**:
    -   **Smart Interface Detection**: Automatically detects physical interfaces (eth/ens/enp), excluding virtual interfaces like Docker or WARP.
    -   **Precise Control**: Supports upload/download rate limiting for specific TCP/UDP ports (Unit: MB/s).
    -   **Visual Management**: Provides real-time bandwidth calculation (Mbps), rule list viewing, and traffic statistics.
    -   **One-Click Maintenance**: Supports clearing all rules and auto-saving configurations for persistence after reboot.

### 2. BBR Optimization Script (`bbr.sh`)

An all-in-one Linux network optimization assistant, integrating various BBR algorithms and system-level parameter tuning, with kernel management support.

-   **Key Features**:
    -   **Kernel Optimization**: Enables BBR, optimizes TCP windows and buffer sizes (default 32MB+) to improve throughput in high-latency networks.
    -   **Aggressive Mode**: A new deep optimization mode for peak hours and network jitter, utilizing `fq_codel` queue algorithm along with `initcwnd=32` and TCP Fast Open to significantly reduce latency and accelerate connection establishment.
    -   **Backup & Restore**: Supports one-click backup of current configurations and provides an immutable "Pristine System Backup" for safe restoration at any time.
    -   **Kernel Management**: Automatically detects BBR versions and supports one-click kernel upgrades for Debian/Ubuntu/CentOS to support BBR.
    -   **Smart Diagnostics**: Built-in network latency/speed tests and a Pre-check mechanism to ensure system environment compliance.
    -   **Quick Command**: Accessible via the `bb` command after installation.

### 3. GOST Proxy Script (`gost-proxy.sh`)

A minimalist deployment tool for GOST tunnel/proxy services (v2.0).

-   **Key Features**:
    -   **Multi-Mode Support**: Supports SOCKS5, HTTP, or co-existing SOCKS5+HTTP dual protocols.
    -   **Multi-Node Management**: Supports adding multiple proxy nodes with independent port and authentication settings.
    -   **Flexible Control**: Supports pausing/resuming specific proxy nodes without affecting other running services.
    -   **Security**: Supports setting username and password authentication.
    -   **Smart Detection**: Automatically checks for port conflicts before deployment.
    -   **Service Daemon**: Automatically creates Systemd service configuration to ensure stable operation.

---

## 🚀 Quick Start

### Method 1: Clone and Run (Recommended)

Suitable for users who need to view source code or manage scripts in batch.

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
# Run the corresponding script, for example:
./Throttle.sh
```

### Method 2: One-Click Command

Load and run scripts directly via the network.

#### 1. Port Throttling
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/Throttle.sh)
```

#### 2. BBR Network Optimization
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh)
```
> After installation, you can directly use the `bb` command to manage it.

#### 3. GOST Proxy Deployment
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh)
```

---

## 📋 System Requirements

-   **OS**: Recommended Debian 10+, Ubuntu 20.04+, CentOS 7+ or other mainstream Linux distributions.
-   **Permissions**: Scripts involve network interface and kernel parameter modifications, so they must be run as `root`.
-   **Dependencies**: Scripts will automatically check and attempt to install basic tools like `curl`, `wget`, `iptables`, `iproute2`, `tar`.

## 🤝 Contributing

Issues for bug reports or suggestions are welcome. Pull Requests to improve the code are also appreciated.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
