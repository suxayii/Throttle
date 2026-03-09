# Linux Network Optimization and Management Toolkit

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Repo%20Size)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?label=Last%20Commit)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

This project provides a set of efficient, easy-to-use Linux server network management and optimization tools. It covers everything from port throttling and BBR kernel optimization to full-featured network profile management (Net Tune Pro) and proxy service deployment.

## 📖 Table of Contents

- [🛠️ Core Tools](#️-core-tools)
  - [1. Net Tune Pro v3 (install.sh / net-tune-pro-v3-zh.sh)](#1-net-tune-pro-v3-installsh--net-tune-pro-v3-zhsh)
  - [2. Port Throttle Tool (Throttle.sh)](#2-port-throttle-tool-throttlesh)
  - [3. BBR Optimization Script (bbr.sh)](#3-bbr-optimization-script-bbrsh)
  - [4. GOST Proxy Script (gost-proxy.sh)](#4-gost-proxy-script-gost-proxysh)
  - [5. nftables Port Forwarding & NAT Optimization (nft-forward.sh)](#5-nftables-port-forwarding--nat-optimization-nft-forwardsh)
  - [6. HTTP/SOCKS5 Proxy Speed Test (http-test.sh)](#6-httpsocks5-proxy-speed-test-http-testsh)
  - [7. Peak Hour Network Diagnosis (peak_test.sh)](#7-peak-hour-network-diagnosis-peak_testsh)
- [🚀 Quick Start](#-quick-start)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🛠️ Core Tools

### 1. Net Tune Pro v3 (`net-tune-pro-v3-zh.sh` / `install.sh`)
**Recommended! The most powerful all-in-one network optimization profile manager.** Integrates various preset optimization plans with atomic configuration and version protection. Updated to v3.3.1 with specialized 1C1G Hysteria2 optimization.

-   **Key Features**:
    -   **12 Optimization Profiles**: Balanced, Aggressive, UDP/QUIC, Low Memory, etc.
    -   **BBR v3 Support**: One-click install/manage high-performance BBR v3 kernels.
    -   **Queue Management**: Supports FQ, FQ_CODEL, CAKE, etc.
    -   **Safety**: Conflict detection, atomic writes, and 20-snapshot rollback.
    -   **s-ui Priority**: One-click Nice=-10 priority for proxy services.

### 2. Port Throttle Tool (`Throttle.sh`)
A precise port throttling tool based on `tc` and `iptables` with automatic physical NIC detection.

### 3. BBR Optimization Script (`bbr.sh`)
A classic tool for BBR enabling and kernel management with aggressive mode support.

### 4. GOST Proxy Script (`gost-proxy.sh`)
Minimalist GOST tunnel deployment supporting SOCKS5, HTTP, SSTP protocols.

### 5. nftables Port Forwarding & NAT Optimization (`nft-forward.sh`)
Modern port forwarding with integrated NAT server depth optimization (Conntrack/ARP/BBR).

### 6. HTTP/SOCKS5 Proxy Speed Test (`http-test.sh`)
Command-line proxy speed testing with latency and 100MB download benchmark.

### 7. Peak Hour Network Diagnosis (`peak_test.sh`)
Designed to diagnose congestion during peak hours, checking load, packet loss, and Bufferbloat.

---

## 🚀 Quick Start (One-Click Run)

Copy and paste the following commands to your terminal:

| Tool Name | One-Click Command (Curl) |
| :--- | :--- |
| **Net Tune Pro v3** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)` |
| **Port Throttle** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)` |
| **BBR Optimization** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)` |
| **GOST Proxy** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)` |
| **nftables Forward & NAT** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)` |
| **Proxy Speed Test** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)` |
| **Peak Hour Diagnosis** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)` |
| **Quick Install Entry** | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/install.sh)` |

---

## 💻 Local Execution

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
./net-tune-pro-v3-zh.sh
```

## 📋 System Requirements

-   **OS**: Debian 10+, Ubuntu 20.04+, CentOS 7+
-   **Permissions**: Must be run as `root`
-   **Dependencies**: `curl`, `wget`, `iptables`, `iproute2` (auto-installed)

## 🤝 Contributing

Issues and Pull Requests are welcome.

## 📄 License

MIT License.
