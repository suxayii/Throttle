# ⚡ Linux Network Optimization & Management Toolkit (Throttle)

![License](https://img.shields.io/github/license/suxayii/Throttle?label=License&color=blue)
![Repo Size](https://img.shields.io/github/repo-size/suxayii/Throttle?label=Size&color=brightgreen)
![Last Commit](https://img.shields.io/github/last-commit/suxayii/Throttle?color=orange)
[🇨🇳 中文文档](README.md) | [🇺🇸 English](README_EN.md)

This toolkit provides high-performance, industrial-grade Linux network management and optimization tools. From kernel-level BBR tuning to application-layer traffic control, it's designed to squeeze every drop of performance out of your server.

---

## 📖 Table of Contents

- [🚀 Quick Start (One-click Run)](#-quick-start-one-click-run)
- [🛠️ Core Tools Overview](#️-core-tools-overview)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🚀 Quick Start (One-click Run)

> [!IMPORTANT]
> **Standardized One-click Commands**. All scripts support remote execution without cloning the repository.

### 💎 Flagship Tool (All-in-one)

**Net Tune Pro v3 (Recommended)**
*Integrates 12+ profiles including BBR v3, s-ui priority, and atomic rollback.*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)
```

### 🛠️ Specialized Management Tools

| Tool Name | Description | One-click Command (Select & Copy) |
| :--- | :--- | :--- |
| **Port Throttle** | `tc+iptables` Precise Limiting | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)` |
| **BBR Optimization** | Kernel Acceleration | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)` |
| **GOST Deployment** | Minimal Multi-protocol Proxy | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)` |
| **Forward & NAT** | `nftables` Forwarding & Tuning | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)` |
| **Proxy Test** | Speed & Connection Bench | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)` |
| **Peak Diagnosis** | Loss/Jitter/QoS Analysis | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)` |
| **s-ui Extreme Priority** | **(NEW)** Nice -20 & Real-time | `bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/s-20.sh)` |

---

## 🛠️ Core Tools Overview

### 🔥 1. Net Tune Pro v3 (`net-tune-pro-v3-zh.sh`)
The ultimate network profile manager. 
- Supports **12 scene-based profiles** (Balanced, Aggressive, Low Memory, etc.).
- Robust rollback mechanism with **20 snapshots**.
- One-click **s-ui priority** enhancement.

### 🚥 2. Port Throttle Tool (`Throttle.sh`)
Precise bandwidth control per port, strictly targeting physical NICs while ignoring Docker/WARP virtual interfaces.

### 🚀 3. s-ui Extreme Priority (`s-20.sh`)
Sets your proxy process to the highest possible system priority (`Nice -20`) and enables `FIFO` real-time scheduling for maximum PPS performance.

### 🌍 4. nftables Forwarding & NAT Tuning (`nft-forward.sh`)
Modern port forwarding combined with NAT depth optimization (Conntrack/ARP tables).

---

## 📋 System Requirements

- **OS**: Debian 10+, Ubuntu 18.04+, CentOS 7+
- **Privileges**: Must be run as `root`

> [!TIP]
> Ensure your server can access `raw.githubusercontent.com` for remote script execution.

## 🤝 Contributing

Love this project? Give us a **Star** ⭐️.
Feel free to open an [Issue](https://github.com/suxayii/Throttle/issues).

## 📄 License

MIT License.
