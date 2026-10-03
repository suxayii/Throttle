# ⚡ Throttle — Linux 网络优化与管理工具集

<p align="center">
  <strong>从内核到应用层，全方位榨干服务器网络性能</strong>
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

本项目提供了一套**高性能、工业级**的 Linux 服务器网络管理与优化脚本集。涵盖 **BBR 内核调优 → sysctl 网络栈深度调参 → 端口限速 / 转发 → 代理部署 → 安全加固 → 晚高峰诊断** 全链路场景，特别针对跨境线路、晚高峰拥塞及低资源 VPS 进行了深度适配。

## ✨ 为什么选择 Throttle？

| 特性 | 描述 |
| --- | --- |
| 🔬 **深度调参** | 不是简单的 `sysctl -w`，而是基于 BDP 计算、连接跟踪优化、网卡中断亲和等维度做系统级优化 |
| 🛡️ **安全回滚** | 全部脚本支持修改前自动备份、快照回滚，改坏了也能一键恢复 |
| 🎯 **场景适配** | 12+ 预设 Profile（平衡 / 激进 / 低内存 / Hysteria2 专项等），开箱即用 |
| 🤖 **自动检测** | 自动识别虚拟化类型（KVM/LXC/Docker）、网卡类型、BBR 版本，无需手动配置 |
| 📊 **诊断能力** | 内置晚高峰质量评估、代理测速、丢包抖动分析、路由推断等诊断工具 |

---

## 📖 目录

- [🚀 快速开始](#-快速开始)
- [🗂️ 工具总览](#️-工具总览)
- [🔥 核心工具详解](#-核心工具详解)
- [📋 系统要求](#-系统要求)
- [🏗️ 项目结构](#️-项目结构)
- [❓ FAQ](#-faq)
- [⚠️ 安全提示](#️-安全提示)
- [🤝 贡献与反馈](#-贡献与反馈)
- [📄 许可证](#-许可证)

---

## 🚀 快速开始

> [!TIP]
> 鼠标悬停在代码块右上角，即可使用 GitHub 提供的一键复制按钮。所有脚本均需 **root 权限**运行。

### 💎 推荐入口（三选一，不可叠加）

> [!IMPORTANT]
> **`net-tune-pro-v3`、`hy2-net-auto-tune`、`bbr.sh` 三者均会修改 sysctl 网络参数，请只选其一使用。**
> 同时运行多个会导致配置文件冲突（它们写入不同的 `/etc/sysctl.d/99-*.conf`），产生不可预期的行为。

**方式一：Net Tune Pro v3 — 全能网络优化（强烈推荐 ⭐）**

整合 12 种优化方案，支持 BBR v3 安装、s-ui 优先级提权、原子化配置保护与 20 次快照回滚。

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/net-tune-pro-v3-zh.sh)
```

**方式二：HY2 Auto Tune — Hysteria2 专项全能优化**

基于 BDP 计算的 sysctl 智能调参，支持 TUI / CLI 双模式、服务端测速、BBR/BBR2 自动检测。

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/hy2-net-auto-tune.sh)
```

**方式三：BBR 优化 — 仅需 BBR + 内核升级时使用**

如果你只需要开启 BBR 和升级内核，不需要完整的网络调优，可以单独使用此脚本。

```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)
```

### 🛠️ 专项工具（按需执行）

<details>
<summary><b>📦 展开查看所有工具一键命令</b></summary>

**端口限速 — `tc` + `iptables` 精准流控**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/Throttle.sh)
```

**BBR 优化 — 内核级加速与内核管理** ⚠️ *与上方推荐入口功能重叠，详见 [FAQ](#-faq)*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/bbr.sh)
```

**GOST 代理部署 — 极简多协议隧道**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/gost-proxy.sh)
```

**nftables 端口转发 — 现代化 NAT 管理**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/nft-forward.sh)
```

**代理测速 — 下载测速与连通性诊断**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/http-test.sh)
```

**晚高峰诊断 — 丢包/抖动/QoS 实时分析**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/peak_test.sh)
```

**s-ui 极致优先级 — Nice -20 & FIFO 90** ⚠️ *临时方案，重启失效；持久化请用 Net Tune Pro 菜单项 6*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/s-20.sh)
```

**SSH 端口管理 — 安全端口变更与密钥配置**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/ssh-port.sh)
```

**服务器安全加固 — UFW 防火墙一键配置**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/sf.sh)
```

**3x-ui + Cloudflare CDN 专享调优 — VLESS-WebSocket 全链路加速**
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/cf-vless-tune.sh)
```

**快捷安装入口 — `install.sh`** *自动拉取最新版 net-tune-pro 执行，支持离线回退*
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/master/install.sh)
```

</details>

---

## 🗂️ 工具总览

> [!NOTE]
> 下表中标注 🔁 的脚本之间存在功能重叠，请参考 [FAQ](#-faq) 选择最适合的一个。

| 脚本 | 版本 | 用途 | 关键特性 | 备注 |
| :--- | :---: | :--- | :--- | :--- |
| `cf-vless-tune.sh` | v1.0 | 🔥 3x-ui + CF CDN 专享加速 | TCP KeepAlive 保活、BBR、3x-ui 提权、Nginx 模板、源站防墙 | 适用 VLESS-WS + CDN 场景 |
| `net-tune-pro-v3-zh.sh` | v3.3.2 | 🔥 全能 sysctl 网络优化 | 12 种 Profile、20 次快照回滚、BBR v3、s-ui 优化 | 🔁 与 hy2/bbr 互斥 |
| `hy2-net-auto-tune.sh` | v2.3.1 | 🔥 Hysteria2 专项调优 | BDP 自动计算、TUI/CLI 双模式、NIC RPS 调优 | 🔁 与 net-tune/bbr 互斥 |
| `bbr.sh` | — | BBR 拥塞控制与内核管理 | 内核升级、BBR 启用/检查、锁文件防并发、自动备份还原 | 🔁 与 net-tune/hy2 互斥 |
| `Throttle.sh` | v6.1 | 端口限速（tc + iptables） | 智能网卡识别、绕过 WARP/Docker 虚拟网卡、实时流量统计 | |
| `gost-proxy.sh` | v2.0 | GOST 代理一键部署 | 多协议支持、节点暂停/恢复、systemd 管理 | |
| `nft-forward.sh` | v4.0 | nftables 端口转发 + NAT 优化 | 连接跟踪优化、ARP 表调优、持久化规则 | |
| `ssh-port.sh` | — | SSH 端口与安全管理 | 双端口过渡、SELinux 适配、密钥登录、防失联回滚 | |
| `sf.sh` | v1.2 | 服务器安全加固 | UFW 一键配置、监听端口扫描、批量放行 | |
| `http-test.sh` | v2.2 | HTTP/SOCKS5 代理测速 | 延迟分析、100MB 下载测速、日志记录 | |
| `peak_test.sh` | v2.2 | 晚高峰网络质量诊断 | 多节点 MTR、TCP 测试、QoS 评分、路由推断 | |
| `s-20.sh` | — | s-ui 进程优先级提权 | Nice -20 + FIFO 实时调度，极致单核 PPS | ⚡ 临时方案，见 FAQ |
| `install.sh` | — | 快捷安装引导 | 自动拉取最新 net-tune-pro 执行，支持离线回退 | |

---

## 🔥 核心工具详解

### 1️⃣ Net Tune Pro v3 (`net-tune-pro-v3-zh.sh`)

**最强大的 Linux 网络"手术刀"** — 一个脚本搞定全部 sysctl 网络优化。

```
┌─────────────────────────────────────────────────┐
│  Net Tune Pro v3.3.2                            │
│                                                 │
│  ┌─────────┐  ┌──────────┐  ┌────────────────┐ │
│  │ 12 种    │  │ 自动检测  │  │ 原子化配置保护 │ │
│  │ Profile  │  │ KVM/LXC  │  │ 20 次快照回滚  │ │
│  └─────────┘  └──────────┘  └────────────────┘ │
│                                                 │
│  支持场景：平衡 ｜ 激进 ｜ Hysteria2 专项       │
│           1C1G 低内存 ｜ 高并发 ｜ 自定义       │
└─────────────────────────────────────────────────┘
```

- **智能化**：自动识别虚拟化架构（KVM / LXC / Docker）与网卡类型
- **场景化**：预设 12 种 Profile（平衡、激进、Hysteria2 专项、1C1G 低内存等）
- **版本化**：支持 20 次快照回滚，修改前自动备份，改坏了也能一键恢复
- **服务优化**：集成 s-ui 优先级调节，确保在 CPU 100% 时代理服务依然丝滑

### 2️⃣ HY2 Network Auto Tune (`hy2-net-auto-tune.sh`)

**专为 Hysteria2 + 跨境线路打造的专业调优工具**，基于实际链路 BDP（带宽延迟积）动态计算最优缓冲区参数。

- **BDP 智能调参**：根据 RTT 和路径带宽自动计算 `net.core.rmem_max` / `wmem_max` 等核心参数
- **双模式**：交互式 TUI（终端菜单）+ 自动化 CLI（支持 `--dry-run` 预览）
- **Profile 支持**：`balanced`（2×BDP，默认）/ `aggressive`（4×BDP，需更多内存）
- **附加功能**：NIC RPS/RFS 中断亲和优化、NOFILE 上限调整、BBR/BBR2 自动检测
- **Hy2 建议**：自动生成 Hysteria2 服务端推荐配置（保存至 `/root/hy2-net-auto-tune/`）

```bash
# CLI 自动化示例
sudo ./hy2-net-auto-tune.sh -y --speedtest --cn-rtt 180 --cn-path-mbps 300
sudo ./hy2-net-auto-tune.sh -y --profile aggressive --cn-rtt 180 --cn-path-mbps 500
sudo ./hy2-net-auto-tune.sh --dry-run --cn-rtt 220
```

### 3️⃣ 端口限速工具 (`Throttle.sh`)

专为 VPS 流量计费设计，使用 `tc` + `iptables` 精准控制单个端口的上下行带宽。

- **避坑逻辑**：自动绕过 Docker / WARP / Cloudflare 等虚拟网卡，直击物理网卡
- **实时监控**：自带流量统计波动查看
- **持久化**：限速规则保存至 `/etc/port-limit/`，重启不丢失

### 4️⃣ BBR 优化脚本 (`bbr.sh`)

**生产安全级** BBR 管理工具，支持内核升级与拥塞控制算法切换。

- **安全机制**：不覆盖 `/etc/sysctl.conf`，使用独立配置文件 `/etc/sysctl.d/99-proxy-tune.conf`
- **锁文件机制**：防止多实例并发运行
- **原始备份**：首次运行自动保存 pristine 系统快照
- **多发行版**：支持 Debian / Ubuntu / CentOS / Rocky 系统检测

### 5️⃣ GOST 代理部署 (`gost-proxy.sh`)

极简一键部署多协议代理隧道，支持 systemd 守护进程管理。

- **多协议**：HTTP / SOCKS5 / 端口转发等多种代理模式
- **节点管理**：支持节点添加、暂停 / 恢复、端口冲突检测
- **服务化**：自动创建 systemd service，支持开机自启

### 6️⃣ nftables 转发与 NAT 调优 (`nft-forward.sh`)

结合 `nftables` 的现代转发管理与 NAT 深度性能优化。

- **端口转发**：基于 nftables 的 DNAT / SNAT 规则管理
- **NAT 优化**：连接跟踪表（Conntrack）扩容、ARP 表参数调优
- **持久化**：规则自动写入 nftables 配置文件，重启生效

### 7️⃣ SSH 端口管理 (`ssh-port.sh`)

**企业级 SSH 安全管理工具**，覆盖 7 大发行版。

- **安全熔断**：关闭 22 端口前强制检测存活的备用端口，防止失联
- **密钥管理**：一键生成 ED25519 密钥对、注入公钥、输出私钥、安全粉碎
- **双端口过渡**：支持新旧端口并存的平滑迁移方案
- **多系统适配**：Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine / Arch

---

## 📋 系统要求

| 项目 | 要求 |
| :--- | :--- |
| **操作系统** | Debian 10+、Ubuntu 18.04+、CentOS 7+、Rocky / AlmaLinux 8+ |
| **架构** | x86_64（主要）、ARM64（部分脚本支持） |
| **权限** | 必须以 `root` 用户运行 |
| **依赖** | `curl`（远程执行必需）；各脚本会自动检测并提示安装其他依赖 |

> [!IMPORTANT]
> 执行任何优化前，强烈建议先通过 `install.sh` 进行系统初始备份。

---

## 🏗️ 项目结构

```
Throttle/
├── net-tune-pro-v3-zh.sh    # 🔥 全能网络优化（核心）
├── hy2-net-auto-tune.sh     # 🔥 Hysteria2 专项调优
├── bbr.sh                   # BBR 拥塞控制与内核管理
├── Throttle.sh              # 端口限速（tc + iptables）
├── gost-proxy.sh            # GOST 多协议代理部署
├── nft-forward.sh           # nftables 端口转发 + NAT 优化
├── ssh-port.sh              # SSH 端口与安全管理
├── sf.sh                    # 服务器安全加固（UFW）
├── http-test.sh             # HTTP/SOCKS5 代理测速
├── peak_test.sh             # 晚高峰网络质量诊断
├── s-20.sh                  # s-ui 进程优先级提权
├── install.sh               # 快捷安装引导（拉取最新 net-tune-pro）
├── sr_cnip_splitdns.conf    # Shadowrocket 分流规则（CN Split DNS）
├── LICENSE                  # MIT License
├── README.md                # 中文文档（本文件）
└── README_EN.md             # English Documentation
```

---

## ❓ FAQ

<details>
<summary><b>Q：脚本修改了什么系统文件？安全吗？</b></summary>

所有优化脚本都**不会**覆盖 `/etc/sysctl.conf`，而是使用独立配置文件（如 `/etc/sysctl.d/99-*.conf`）。每次修改前会自动创建备份，可随时回滚。
</details>

<details>
<summary><b>Q：net-tune-pro / hy2-auto-tune / bbr.sh 三者什么关系？能同时用吗？</b></summary>

**不能同时使用。** 三者都会写入 `/etc/sysctl.d/` 下的不同配置文件，同时生效会导致参数冲突：

| 脚本 | 写入文件 | 定位 |
| :--- | :--- | :--- |
| `net-tune-pro-v3` | `99-net-tune-pro-v3.conf` | 全能型，12 种场景 Profile |
| `hy2-net-auto-tune` | `99-hy2-net-auto-tune.conf` | Hysteria2 专项，BDP 动态计算 |
| `bbr.sh` | `99-proxy-tune.conf` | 轻量型，仅 BBR + 基础缓冲区 |

**选择建议**：
- 只跑 Hysteria2 → 选 `hy2-net-auto-tune`（参数最精准）
- 场景多样或不确定 → 选 `net-tune-pro-v3`（覆盖面最广）
- 只需开启 BBR + 升级内核 → 选 `bbr.sh`（最轻量）

如果之前用过其中一个，切换到另一个时，新脚本会自动覆盖或清理旧配置（`hy2-net-auto-tune` 会主动清理 `net-tune-pro` 的旧文件）。
</details>

<details>
<summary><b>Q：s-20.sh 和 Net Tune Pro 的 s-ui 优先级功能有什么区别？</b></summary>

| 对比 | `s-20.sh` | Net Tune Pro 菜单项 6 |
| :--- | :--- | :--- |
| **方式** | `renice -20` + `chrt -f 90`（直接操作进程） | systemd override（`Nice=-10` + `LimitNOFILE`） |
| **持久性** | ❌ 重启后失效 | ✅ 持久化，重启自动生效 |
| **力度** | 更激进（Nice -20, FIFO 90） | 更温和（Nice -10） |

**建议**：日常使用请通过 Net Tune Pro 菜单项 6 设置持久化优先级。`s-20.sh` 适合临时紧急提权（如晚高峰期间临时提升）。
</details>

<details>
<summary><b>Q：install.sh 和 net-tune-pro-v3-zh.sh 是什么关系？</b></summary>

`install.sh` 是一个**轻量引导脚本**，运行后会自动从 GitHub 拉取最新版 `net-tune-pro-v3-zh.sh` 并执行。如果网络不可用，它会回退到本地已缓存的版本（`/root/net-tune-pro-v3-zh.sh`）。

两者效果相同，`install.sh` 只是多了一层下载 + 缓存逻辑。
</details>

<details>
<summary><b>Q：LXC / OpenVZ 容器能用吗？</b></summary>

LXC / OpenVZ 容器无法修改内核参数（`sysctl` 受限）。脚本会自动检测虚拟化类型并给出相应提示。建议在 **KVM / 独立服务器** 上使用。
</details>

<details>
<summary><b>Q：优化后网络变差了怎么办？</b></summary>

- **Net Tune Pro v3**：使用脚本内置的回滚功能，从 20 个历史快照中恢复
- **HY2 Auto Tune**：重新运行脚本，切换到 `balanced` Profile 或执行回滚
- **BBR 脚本**：运行脚本选择还原选项，可恢复到原始备份
- **手动恢复**：删除 `/etc/sysctl.d/99-*.conf` 相关文件，然后执行 `sysctl --system`
</details>

<details>
<summary><b>Q：Shadowrocket 分流规则（sr_cnip_splitdns.conf）怎么用？</b></summary>

这是一份经过深度定制的 Shadowrocket 配置文件，包含：
- 国内直连 + 海外代理 + Split DNS 分流
- AI 服务（ChatGPT / Claude / Cursor）强制远端 DNS
- Hysteria2 DNS 弹性 + Discord / Telegram 优化
- 抗审查加固（私有 IP 屏蔽、SNI、DoT→DoH 降级）

将文件内容导入 Shadowrocket 的「配置」即可使用。
</details>

---

## ⚠️ 安全提示

> [!WARNING]
> - 所有脚本必须以 **root 权限** 运行，请确保你了解每个脚本的行为
> - 建议在**测试环境**验证后再应用到生产服务器
> - 首次使用请通过 `install.sh` 创建系统基线备份
> - 内核升级（BBR 脚本）可能需要重启服务器，请确保有控制台访问权限

> [!CAUTION]
> 请勿在**关键生产服务器**上未经测试直接运行优化脚本。虽然所有脚本都支持回滚，但网络参数变更可能导致短暂的连接中断。

---

## 🤝 贡献与反馈

如果你觉得好用，欢迎点一个 **Star** ⭐️，这是对项目最大的支持！

- 🐛 发现 Bug？请提交 [Issue](https://github.com/suxayii/Throttle/issues)
- 💡 有新想法？欢迎提交 [Pull Request](https://github.com/suxayii/Throttle/pulls)
- 💬 使用交流？请在 Issue 中讨论

---

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。

Copyright © 2026 [suxayii](https://github.com/suxayii)
