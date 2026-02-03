# Linux 网络优化与管理工具集

本项目包含一组用于 Linux 服务器网络管理、优化和代理部署的 Shell 脚本。

## 包含的工具

### 1. 端口限速工具 (`Throttle.sh`)

一个用于限制特定端口流量速率的脚本，基于 `tc` (Traffic Control) 和 `iptables`。

-   **功能特点**：
    -   自动识别物理网卡（支持排除虚拟网卡如 WARP/WireGuard）。
    -   支持对指定端口（TCP/UDP）进行上传/下载限速。
    -   支持小数限速设置（例如 0.5 MB/s）。
    -   提供状态查看和一键清除规则功能。
    -   自动保存配置，重启后可查看当前状态。

### 2. BBR 网络优化脚本 (`bbr.sh`)

一键开启 BBR 拥塞控制并优化 Linux 网络内核参数。

-   **功能特点**：
    -   自动检测并开启 BBR。
    -   优化 TCP 窗口、缓冲区等内核参数 (`sysctl.conf`)。
    -   支持选择队列调度算法 (`fq` 或 `fq_codel`)。
    -   自动备份原始配置文件。
    -   内置 `iperf3` 带宽测试功能（可选）。

### 3. GOST 代理部署脚本 (`gost-proxy.sh`)

用于快速部署和管理 GOST 代理服务的脚本。

-   **功能特点**：
    -   一键安装/更新 GOST。
    -   配置 SOCKS5、HTTP 或双协议代理。
    -   支持用户名/密码认证。
    -   自动创建并管理 systemd 服务 (开机自启、重启)。
    -   内置 BBR 网络优化选项。
    -   支持管理多个代理节点（添加、暂停、恢复）。

## 使用方法

首先克隆本仓库到您的服务器：

```bash
git clone https://github.com/suxayii/Throttle.git
cd Throttle
chmod +x *.sh
```
### 1. 端口限速工具 (`Throttle.sh`)
**一键运行**:
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/Throttle.sh)
```

### 2. BBR 网络优化脚本 (`bbr.sh`)
**一键运行**:
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh)
```

### 3. GOST 代理部署脚本 (`gost-proxy.sh`)
**一键运行**:
```bash
bash <(curl -sL https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh)
```

## 系统要求

-   **操作系统**: 推荐使用 Debian / Ubuntu / CentOS 等主流 Linux 发行版。
-   **权限**: 脚本需要 root 权限运行。

## 许可证

MIT License
