# ⚡ Throttle — Linux Network Optimization & Management Toolkit

<p align="center">
  <strong>Squeeze every drop of performance from your server's network stack</strong>
</p>

<p align="center">
  <a href="https://github.com/suxayii/Throttle/blob/master/LICENSE"><img src="https://img.shields.io/github/license/suxayii/Throttle?label=License&color=blue" alt="License"></a>
  <img src="https://img.shields.io/github/repo-size/suxayii/Throttle?label=Size&color=brightgreen" alt="Repo Size">
  <img src="https://img.shields.io/github/last-commit/suxayii/Throttle?color=orange" alt="Last Commit">
  <img src="https://img.shields.io/github/stars/suxayii/Throttle?style=social" alt="Stars">
</p>

<p align="center">
  <a href="README.md">🇨🇳 中文文档</a> ｜ <a href="README_EN.md">🇺🇸 English</a>
</p>

---

A collection of **high-performance, production-grade** shell scripts for Linux server network management and optimization. Covers the full stack — from **kernel-level BBR tuning → sysctl deep-tuning → port throttling / forwarding → proxy deployment → security hardening → peak-hour diagnostics** — with special focus on cross-border links, peak-hour congestion, and resource-constrained VPS environments.

## ✨ Why Throttle?

| Feature | Description |
| --- | --- |
| 🔬 **Deep Tuning** | Goes far beyond `sysctl -w` — optimizes based on BDP calculations, conntrack tuning, NIC interrupt affinity, and more |
| 🛡️ **Safe Rollback** | All scripts auto-backup before changes; snapshot rollback available at any time |
| 🎯 **Scenario Profiles** | 12+ pre-built profiles (Balanced, Aggressive, Low-memory, Hysteria2-specific, etc.) |
| 🤖 **Auto Detection** | Automatically identifies virtualization type (KVM/LXC/Docker), NIC type, and BBR version |
| 📊 **Diagnostics** | Built-in peak-hour quality assessment, proxy speed testing, packet loss / jitter analysis, and route inference |

---

## 📖 Table of Contents

- [🚀 Quick Start](#-quick-start)
- [🗂️ Tools Overview](#️-tools-overview)
- [🔥 Core Tools In-Depth](#-core-tools-in-depth)
- [📋 System Requirements](#-system-requirements)
- [🏗️ Project Structure](#️-project-structure)
- [❓ FAQ](#-faq)
- [⚠️ Security Notes](#️-security-notes)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## 🚀 Quick Start

> [!TIP]
> Hover over the top-right corner of any code block to use GitHub's built-in copy button. All scripts require **root** privileges.

### 💎 Recommended Entry Points (Pick One — Do NOT Stack)

> [!IMPORTANT]
> **`net-tune-pro-v3`, `hy2-net-auto-tune`, and `bbr.sh` all modify sysctl network parameters. Use only ONE of them.**
> Running multiple at the same time causes config file conflicts (they write to different `/etc/sysctl.d/99-*.conf` files), leading to unpredictable behavior.

**Option A: Net Tune Pro v3 — All-in-One Optimizer (Recommended ⭐)**

Integrates 12 optimization profiles with BBR v3 support, s-ui priority tuning, atomic config protection, and 20-snapshot rollback.

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)
```

**Option B: HY2 Auto Tune — Hysteria2-Specific Optimizer**

BDP-based intelligent sysctl tuning with TUI/CLI dual-mode, server-side speedtest, and BBR/BBR2 auto-detection.

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/hy2-net-auto-tune.sh)
```

**Option C: BBR Optimization — Use when you only need BBR + kernel upgrade**

If you only need to enable BBR and upgrade the kernel without full network tuning, use this standalone script.

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)
```

### 🛠️ Specialized Tools (On-Demand)

<details>
<summary><b>📦 Expand to see all one-liner commands</b></summary>

**Port Throttle — tc + iptables Precise Limiting**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)
```

**BBR Optimization — Kernel-level Acceleration** ⚠️ *Overlaps with recommended entries above, see [FAQ](#-faq)*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)
```

**GOST Proxy Deployment — Minimal Multi-protocol Tunnel**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)
```

**nftables Port Forwarding — Modern NAT Management**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)
```

**Proxy Speed Test — Download & Connectivity Benchmarking**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)
```

**Peak-hour Diagnostics — Loss / Jitter / QoS Analysis**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)
```

**s-ui Extreme Priority — Nice -20 & FIFO 90** ⚠️ *Temporary fix, lost on reboot; for persistent setup use Net Tune Pro menu item 6*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/s-20.sh)
```

**SSH Port Management — Secure Port Change & Key Setup**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/ssh-port.sh)
```

**Server Hardening — UFW Firewall Setup**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/sf.sh)
```

**3x-ui + Cloudflare CDN Optimizer — VLESS-WebSocket Tuning**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/cf-vless-tune.sh)
```

**Quick Install Entry — `install.sh`** *Auto-fetches latest net-tune-pro and runs it, with offline fallback*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/install.sh)
```

</details>

---

## 🗂️ Tools Overview

> [!NOTE]
> Scripts marked with 🔁 below have overlapping functionality. See [FAQ](#-faq) to pick the right one.

| Script | Version | Purpose | Key Features | Note |
| :--- | :---: | :--- | :--- | :--- |
| `cf-vless-tune.sh` | v1.0 | 🔥 3x-ui + CF CDN Optimization | TCP KeepAlive keep-alive, BBR, 3x-ui priority, Nginx template, origin firewall | For VLESS-WS + CDN setups |
| `net-tune-pro-v3-zh.sh` | v3.3.2 | 🔥 All-in-one sysctl optimizer | 12 profiles, 20-snapshot rollback, BBR v3, s-ui tuning | 🔁 Exclusive with hy2/bbr |
| `hy2-net-auto-tune.sh` | v2.3.1 | 🔥 Hysteria2-specific tuning | BDP auto-calc, TUI/CLI modes, NIC RPS tuning | 🔁 Exclusive with net-tune/bbr |
| `bbr.sh` | — | BBR congestion control & kernel mgmt | Kernel upgrade, lock-file safety, auto backup/restore | 🔁 Exclusive with net-tune/hy2 |
| `Throttle.sh` | v6.1 | Port throttling (tc + iptables) | Smart NIC detection, bypasses WARP/Docker, live stats | |
| `gost-proxy.sh` | v2.0 | GOST multi-protocol proxy | Node pause/resume, port conflict detection, systemd | |
| `nft-forward.sh` | v4.0 | nftables forwarding + NAT tuning | Conntrack optimization, ARP tuning, persistent rules | |
| `ssh-port.sh` | — | SSH port & security management | Dual-port transition, SELinux, key auth, anti-lockout | |
| `sf.sh` | v1.2 | Server security hardening | UFW setup, port scanning, batch allow | |
| `http-test.sh` | v2.2 | HTTP/SOCKS5 proxy speed test | Latency analysis, 100MB download test, logging | |
| `peak_test.sh` | v2.2 | Peak-hour network diagnostics | Multi-node MTR, TCP test, QoS scoring, route inference | |
| `s-20.sh` | — | s-ui process priority boost | Nice -20 + FIFO real-time scheduling, max PPS | ⚡ Temporary, see FAQ |
| `install.sh` | — | Quick install bootstrap | Auto-fetches latest net-tune-pro, offline fallback | |

---

## 🔥 Core Tools In-Depth

### 1️⃣ Net Tune Pro v3 (`net-tune-pro-v3-zh.sh`)

**The ultimate Linux network "surgical knife"** — one script to handle all sysctl network optimization.

- **Intelligent**: Auto-detects virtualization (KVM / LXC / Docker) and NIC types
- **Scenario-based**: 12 pre-built profiles (Balanced, Aggressive, Hysteria2, Low-memory 1C1G, etc.)
- **Versioned**: 20-snapshot rollback with automatic pre-change backup
- **Service-aware**: Integrated s-ui priority tuning for smooth proxy service under high CPU load

### 2️⃣ HY2 Network Auto Tune (`hy2-net-auto-tune.sh`)

**Purpose-built for Hysteria2 + cross-border links**, dynamically calculates optimal buffer parameters based on actual link BDP (Bandwidth-Delay Product).

- **BDP-based tuning**: Auto-calculates `net.core.rmem_max` / `wmem_max` from RTT and path bandwidth
- **Dual-mode**: Interactive TUI (terminal menu) + automated CLI (with `--dry-run` preview)
- **Profiles**: `balanced` (2×BDP, default) / `aggressive` (4×BDP, more RAM needed)
- **Extras**: NIC RPS/RFS interrupt affinity, NOFILE limit adjustment, BBR/BBR2 auto-detection

```bash
# CLI automation examples
sudo ./hy2-net-auto-tune.sh -y --speedtest --cn-rtt 180 --cn-path-mbps 300
sudo ./hy2-net-auto-tune.sh -y --profile aggressive --cn-rtt 180 --cn-path-mbps 500
sudo ./hy2-net-auto-tune.sh --dry-run --cn-rtt 220
```

### 3️⃣ Port Throttle (`Throttle.sh`)

Designed for VPS billing control — precisely limits upload/download bandwidth per port using `tc` + `iptables`.

- **Smart NIC detection**: Bypasses Docker / WARP / Cloudflare virtual interfaces, targets physical NICs
- **Live monitoring**: Built-in real-time traffic statistics
- **Persistent**: Rules saved to `/etc/port-limit/`, survive reboots

### 4️⃣ BBR Optimization (`bbr.sh`)

**Production-safe** BBR management with kernel upgrade and congestion control switching.

- **Safe config**: Uses `/etc/sysctl.d/99-proxy-tune.conf` — never overwrites `/etc/sysctl.conf`
- **Concurrency-safe**: Lock-file mechanism prevents parallel execution
- **Pristine backup**: Automatically preserves original system snapshot on first run

### 5️⃣ SSH Port Manager (`ssh-port.sh`)

**Enterprise-grade SSH security** across 7 Linux distributions.

- **Anti-lockout**: Refuses to close port 22 unless an active alternate port is verified
- **Key management**: One-click ED25519 key generation, public key injection, secure private key shredding
- **Smooth migration**: Dual-port transition support for zero-downtime port changes
- **Multi-distro**: Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine / Arch

---

## 📋 System Requirements

| Item | Requirement |
| :--- | :--- |
| **OS** | Debian 10+, Ubuntu 18.04+, CentOS 7+, Rocky / AlmaLinux 8+ |
| **Architecture** | x86_64 (primary), ARM64 (partial support) |
| **Privileges** | Must run as `root` |
| **Dependencies** | `curl` (required for remote execution); scripts auto-detect and prompt for others |

> [!IMPORTANT]
> Always perform a baseline backup via `install.sh` before applying major optimizations.

---

## 🏗️ Project Structure

```
Throttle/
├── net-tune-pro-v3-zh.sh    # 🔥 All-in-one network optimizer (core)
├── hy2-net-auto-tune.sh     # 🔥 Hysteria2-specific tuning
├── bbr.sh                   # BBR congestion control & kernel management
├── Throttle.sh              # Port throttling (tc + iptables)
├── gost-proxy.sh            # GOST multi-protocol proxy deployment
├── nft-forward.sh           # nftables forwarding + NAT optimization
├── ssh-port.sh              # SSH port & security management
├── sf.sh                    # Server security hardening (UFW)
├── http-test.sh             # HTTP/SOCKS5 proxy speed test
├── peak_test.sh             # Peak-hour network diagnostics
├── s-20.sh                  # s-ui process priority boost
├── install.sh               # Quick install bootstrap (fetches latest net-tune-pro)
├── sr_cnip_splitdns.conf    # Shadowrocket split-DNS rules (CN)
├── LICENSE                  # MIT License
├── README.md                # 中文文档
└── README_EN.md             # English Documentation (this file)
```

---

## ❓ FAQ

<details>
<summary><b>Q: What system files do the scripts modify? Is it safe?</b></summary>

All optimization scripts use **isolated config files** (e.g., `/etc/sysctl.d/99-*.conf`) and **never overwrite** `/etc/sysctl.conf`. Every change is automatically backed up and can be rolled back at any time.
</details>

<details>
<summary><b>Q: net-tune-pro / hy2-auto-tune / bbr.sh — what's the relationship? Can I use them together?</b></summary>

**No, do not use them together.** All three write to different config files under `/etc/sysctl.d/`, causing parameter conflicts when active simultaneously:

| Script | Config File | Focus |
| :--- | :--- | :--- |
| `net-tune-pro-v3` | `99-net-tune-pro-v3.conf` | All-in-one, 12 scenario profiles |
| `hy2-net-auto-tune` | `99-hy2-net-auto-tune.conf` | Hysteria2-specific, BDP-based |
| `bbr.sh` | `99-proxy-tune.conf` | Lightweight, BBR + basic buffers only |

**How to choose**:
- Hysteria2 only → `hy2-net-auto-tune` (most precise parameters)
- Mixed workloads or unsure → `net-tune-pro-v3` (broadest coverage)
- Just need BBR + kernel upgrade → `bbr.sh` (lightest weight)

When switching from one to another, the new script will automatically override or clean up old configs (`hy2-net-auto-tune` actively removes `net-tune-pro` legacy files).
</details>

<details>
<summary><b>Q: What's the difference between s-20.sh and Net Tune Pro's s-ui priority feature?</b></summary>

| Comparison | `s-20.sh` | Net Tune Pro menu item 6 |
| :--- | :--- | :--- |
| **Method** | `renice -20` + `chrt -f 90` (direct PID) | systemd override (`Nice=-10` + `LimitNOFILE`) |
| **Persistence** | ❌ Lost on reboot | ✅ Persistent, auto-applied on restart |
| **Aggressiveness** | Higher (Nice -20, FIFO 90) | Moderate (Nice -10) |

**Recommendation**: Use Net Tune Pro menu item 6 for daily use (persistent). Use `s-20.sh` only for temporary emergency boosts (e.g., during peak hours).
</details>

<details>
<summary><b>Q: What's the relationship between install.sh and net-tune-pro-v3-zh.sh?</b></summary>

`install.sh` is a **lightweight bootstrap script** that automatically fetches the latest `net-tune-pro-v3-zh.sh` from GitHub and runs it. If the network is unavailable, it falls back to the locally cached version (`/root/net-tune-pro-v3-zh.sh`).

Both produce the same result — `install.sh` simply adds a download + cache layer.
</details>

<details>
<summary><b>Q: Does it work on LXC / OpenVZ containers?</b></summary>

LXC / OpenVZ containers cannot modify kernel parameters (`sysctl` is restricted). Scripts will auto-detect the virtualization type and warn accordingly. Recommended for **KVM / bare-metal** servers.
</details>

<details>
<summary><b>Q: Optimization made things worse — how to revert?</b></summary>

- **Net Tune Pro v3**: Use the built-in rollback feature (20 history snapshots)
- **HY2 Auto Tune**: Re-run the script, switch to `balanced` profile or execute rollback
- **BBR script**: Run the script and select the restore option
- **Manual**: Remove `/etc/sysctl.d/99-*.conf` files and run `sysctl --system`
</details>

---

## ⚠️ Security Notes

> [!WARNING]
> - All scripts require **root privileges** — make sure you understand each script's behavior
> - Test in a **staging environment** before applying to production servers
> - Create a system baseline backup via `install.sh` on first use
> - Kernel upgrades (BBR script) may require a server reboot — ensure console access

> [!CAUTION]
> Do **not** run optimization scripts on critical production servers without prior testing. While all scripts support rollback, network parameter changes may cause brief connectivity interruptions.

---

## 🤝 Contributing

If you find this useful, please give us a **Star** ⭐️ — it's the best support!

- 🐛 Found a bug? Open an [Issue](https://github.com/suxayii/Throttle/issues)
- 💡 Have an idea? Submit a [Pull Request](https://github.com/suxayii/Throttle/pulls)
- 💬 Questions? Discuss in [Issues](https://github.com/suxayii/Throttle/issues)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

Copyright © 2026 [suxayii](https://github.com/suxayii)
