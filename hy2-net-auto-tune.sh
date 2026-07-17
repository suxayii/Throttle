#!/usr/bin/env bash
# hy2-net-auto-tune.sh
# Hy2 Network Auto Tune Pro — commercial-style TUI + CLI for CN/Hy2 sysctl tuning.
#
# TUI (default on TTY):
#   sudo ./hy2-net-auto-tune.sh
#
# CLI (automation):
#   sudo ./hy2-net-auto-tune.sh -y --speedtest --cn-rtt 180 --cn-path-mbps 300
#   sudo ./hy2-net-auto-tune.sh -y --profile aggressive --cn-rtt 180 --cn-path-mbps 500
#   sudo ./hy2-net-auto-tune.sh --dry-run --cn-rtt 220
#
# Notes:
# - Server-side speedtest measures VPS↔Internet, NOT China↔VPS path quality.
# - Default assumes ~LA + mainland CN: RTT 200ms, path cap auto-derived from tier/speedtest.
# - Profile: balanced (default, 2×BDP) | aggressive (4×BDP, higher caps; needs more RAM).
# - Also: health diag, NOFILE, Hy2 suggestions, optional NIC/CPU/memory tune, BBR/BBR2 detect.

set -euo pipefail

SCRIPT_VERSION="2.3.1"
CONF_PATH="/etc/sysctl.d/99-hy2-net-auto-tune.conf"
CPU_MEM_CONF_PATH="/etc/sysctl.d/99-hy2-cpu-mem.conf"
LEGACY_PATHS=(
  "/etc/sysctl.d/99-net-tune-pro-v3.conf"
)
BACKUP_ROOT="/root/sysctl-backup"
SYSCTL_LOG="/tmp/hy2-net-auto-tune-sysctl.log"
NOFILE_TARGET=1048576
NIC_TUNE_SCRIPT="/usr/local/sbin/hy2-nic-rps.sh"
NIC_TUNE_SERVICE="/etc/systemd/system/hy2-nic-rps.service"
CPU_MEM_RUNTIME_SCRIPT="/usr/local/sbin/hy2-cpu-mem-runtime.sh"
CPU_MEM_RUNTIME_SERVICE="/etc/systemd/system/hy2-cpu-mem-runtime.service"
HY2_SUGGEST_DIR="/root/hy2-net-auto-tune"

IFACE=""
DO_SPEEDTEST=0
DRY_RUN=0
APPLY=1
CN_RTT_MS=""
CN_PATH_MBPS=""
FORCE_TIER=""
PROFILE="balanced"   # balanced | aggressive
QUIET=0
ASSUME_YES=0
CLI_MODE=0
MENU_MODE=0
SHOW_CONF_PREVIEW=1
SPEEDTEST_FLAG=""
REGION_NAME=""
UI_BACKEND="ansi"   # whiptail | dialog | ansi
DO_NIC_TUNE=0       # optional NIC RPS apply during optimize
SKIP_DEPS_CHECK=0
DEPS_VERBOSE=1      # 0=quiet minimal; still die on hard miss
# Auto-install: -1=ask when missing (default), 0=never, 1=always (or with -y)
AUTO_INSTALL_DEPS=-1

ST_DOWN_MBPS=""
ST_UP_MBPS=""
ST_METHOD="skipped"
ST_OK=0
BDP_HEADROOM=2
UDP_RMEM_MIN=8192
UDP_WMEM_MIN=8192

# Congestion control (feature 9)
CC_ALGO="bbr"           # bbr | bbr2 | cubic...
CC_AVAILABLE=""
CC_PREFERRED="bbr"
CC_MODULE_OK=0
CC_FQ_OK=0
KERNEL_VERSION=""

# ═══════════════════════════════════════════════════════════
# UI layer
# ═══════════════════════════════════════════════════════════

_ui_init() {
  USE_COLOR=0
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    USE_COLOR=1
  fi
  if [[ "$USE_COLOR" -eq 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
    C_GRAY=$'\033[90m'
    C_BG_BLUE=$'\033[44m'
    C_WHITE=$'\033[97m'
  else
    C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE=
    C_CYAN= C_MAGENTA= C_GRAY= C_BG_BLUE= C_WHITE=
  fi

  UI_BACKEND="ansi"
  if command -v whiptail &>/dev/null; then
    UI_BACKEND="whiptail"
  elif command -v dialog &>/dev/null; then
    UI_BACKEND="dialog"
  fi
  # Force ANSI for pure menu-style “安装脚本” look unless --dialog
  if [[ "${FORCE_DIALOG:-0}" != "1" ]]; then
    UI_BACKEND="ansi"
  fi
}

_ui_init

is_tty() { [[ -t 0 && -t 1 ]]; }

log()  { [[ "$QUIET" -eq 1 ]] || printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { [[ "$QUIET" -eq 1 ]] || printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { [[ "$QUIET" -eq 1 ]] || printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

clear_screen() {
  [[ "$QUIET" -eq 1 ]] && return
  if is_tty; then
    printf '\033[H\033[2J' 2>/dev/null || clear 2>/dev/null || true
  fi
}

pause_enter() {
  [[ "$QUIET" -eq 1 ]] && return
  if ! is_tty; then
    return
  fi
  printf '\n%s按回车返回菜单...%s' "$C_DIM" "$C_RESET"
  read -r _ || true
  printf '\n'
}

hr() {
  [[ "$QUIET" -eq 1 ]] && return
  printf '%s────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
}

box_title() {
  local title="$1"
  [[ "$QUIET" -eq 1 ]] && return
  # Fixed-width box; avoid byte-width printf padding (breaks CJK).
  cat <<EOF
${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════╗
║  ${title}
╚══════════════════════════════════════════════╝${C_RESET}
EOF
}

# progress_bar pct width label
progress_bar() {
  local pct="$1" width="${2:-28}" label="${3:-}"
  local filled empty i
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  printf '\r%s%s%s [' "$C_BLUE" "$label" "$C_RESET"
  for ((i = 0; i < filled; i++)); do printf '%s█%s' "$C_GREEN" "$C_RESET"; done
  for ((i = 0; i < empty; i++)); do printf '%s░%s' "$C_GRAY" "$C_RESET"; done
  printf '] %3d%%' "$pct"
}

# Animate fake progress while a background PID runs; ends at 95% until join.
progress_wait_pid() {
  local pid="$1" label="${2:-处理中}"
  local pct=0
  while kill -0 "$pid" 2>/dev/null; do
    progress_bar "$pct" 28 "$label"
    sleep 0.25
    if (( pct < 95 )); then
      pct=$(( pct + RANDOM % 4 + 1 ))
      (( pct > 95 )) && pct=95
    fi
  done
  progress_bar 100 28 "$label"
  printf '\n'
  wait "$pid" 2>/dev/null || true
}

prompt_yes_no() {
  local q="$1" def="${2:-y}" ans hint
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    REPLY_YN=1
    return 0
  fi
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '%s?%s %s [%s]: ' "$C_YELLOW" "$C_RESET" "$q" "$hint"
    if ! read -r ans; then ans=""; fi
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="$def"
    case "$ans" in
      y|yes) REPLY_YN=1; return 0 ;;
      n|no)  REPLY_YN=0; return 0 ;;
      *) printf '  %s请输入 y 或 n%s\n' "$C_DIM" "$C_RESET" ;;
    esac
  done
}

prompt_value() {
  local label="$1" def="${2:-}" validator="${3:-}" ans
  while true; do
    if [[ -n "$def" ]]; then
      printf '%s?%s %s %s[默认: %s]%s\n> ' "$C_YELLOW" "$C_RESET" "$label" "$C_DIM" "$def" "$C_RESET"
    else
      printf '%s?%s %s\n> ' "$C_YELLOW" "$C_RESET" "$label"
    fi
    if ! read -r ans; then ans=""; fi
    if [[ -z "$ans" ]]; then
      REPLY_VAL="$def"
    else
      REPLY_VAL="$ans"
    fi
    if [[ -n "$validator" ]]; then
      "$validator" "$REPLY_VAL" && return 0
      continue
    fi
    return 0
  done
}

prompt_menu() {
  # prompt_menu "请输入"  → sets REPLY_VAL
  local prompt="${1:-请输入}"
  printf '%s%s%s ' "$C_BOLD$C_CYAN" "$prompt" "$C_RESET"
  if ! read -r REPLY_VAL; then
    REPLY_VAL=""
  fi
}

_validate_positive_int() {
  local v="$1"
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    return 0
  fi
  printf '  %s请输入正整数%s\n' "$C_DIM" "$C_RESET"
  return 1
}

_validate_optional_positive_int() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  _validate_positive_int "$v"
}

# ═══════════════════════════════════════════════════════════
# CLI help / parse
# ═══════════════════════════════════════════════════════════

usage() {
  cat <<EOF
${C_BOLD}Hy2 Network Auto Tune Pro${C_RESET}  v${SCRIPT_VERSION}
中国优化 · Hysteria2 内核网络调优工具

${C_BOLD}交互菜单:${C_RESET}
  sudo $0

${C_BOLD}命令行:${C_RESET}
  sudo $0 -y [--speedtest] [--cn-rtt MS] [--cn-path-mbps N] [--tier T]
  sudo $0 -y --profile aggressive --cn-rtt 180 --cn-path-mbps 500
  sudo $0 --dry-run [--cn-rtt MS]
  sudo $0 --menu                 强制菜单模式
  sudo $0 --status              仅显示系统状态
  sudo $0 --diagnose            网络健康诊断
  sudo $0 --hy2-suggest         输出 Hy2 建议带宽
  sudo $0 --nofile-fix          修复常见面板/Hy2 的 LimitNOFILE
  sudo $0 --apply-nic           仅应用网卡 RPS/XPS
  sudo $0 --cpu-tune            CPU 优化（governor + 调度相关）
  sudo $0 --mem-tune            内存优化（vm.* + THP）
  sudo $0 --cpu-mem-tune        CPU + 内存一并优化
  sudo $0 --check-deps          仅运行依赖自检
  sudo $0 --check-deps -y       自检并自动 apt 安装缺失包
  sudo $0 --uninstall           卸载优化配置

${C_BOLD}选项:${C_RESET}
  --speedtest / --no-speedtest
  --cn-rtt MS / --cn-path-mbps N
  --tier small|medium|large
  --profile balanced|aggressive  配置风格（默认 balanced）
  --cc bbr|bbr2|auto             拥塞控制（默认 auto：优先 bbr2）
  --nic-tune                     写入 sysctl 时顺带应用网卡 RPS
  --skip-deps                    跳过启动依赖自检
  --auto-install-deps            缺失时自动 apt 安装（Debian/Ubuntu）
  --no-auto-install-deps         禁止自动安装，仅提示
  --iface IFACE / --conf PATH
  -y, --yes                     跳过确认（含依赖安装确认）
  --dry-run / --no-apply
  -q, --quiet / -h, --help
EOF
}

CC_FORCE=""   # empty | auto | bbr | bbr2

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --speedtest) DO_SPEEDTEST=1; SPEEDTEST_FLAG=set; CLI_MODE=1; shift ;;
      --no-speedtest) DO_SPEEDTEST=0; SPEEDTEST_FLAG=force-off; CLI_MODE=1; shift ;;
      --dry-run) DRY_RUN=1; APPLY=0; CLI_MODE=1; shift ;;
      --no-apply) APPLY=0; CLI_MODE=1; shift ;;
      --cn-rtt) CN_RTT_MS="${2:-}"; CLI_MODE=1; shift 2 ;;
      --cn-path-mbps) CN_PATH_MBPS="${2:-}"; CLI_MODE=1; shift 2 ;;
      --tier) FORCE_TIER="${2:-}"; CLI_MODE=1; shift 2 ;;
      --profile) PROFILE="${2:-}"; CLI_MODE=1; shift 2 ;;
      --cc) CC_FORCE="${2:-auto}"; CLI_MODE=1; shift 2 ;;
      --nic-tune) DO_NIC_TUNE=1; shift ;;
      --apply-nic) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="nic-tune"; shift ;;
      --cpu-tune) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="cpu-tune"; shift ;;
      --mem-tune) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="mem-tune"; shift ;;
      --cpu-mem-tune) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="cpu-mem-tune"; shift ;;
      --iface) IFACE="${2:-}"; CLI_MODE=1; shift 2 ;;
      --conf) CONF_PATH="${2:-}"; CLI_MODE=1; shift 2 ;;
      --no-preview) SHOW_CONF_PREVIEW=0; shift ;;
      --menu) MENU_MODE=1; shift ;;
      --status) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="status"; shift ;;
      --diagnose|--diag) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="diagnose"; shift ;;
      --hy2-suggest) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="hy2-suggest"; shift ;;
      --nofile-fix) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="nofile-fix"; shift ;;
      --check-deps|--deps) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="check-deps"; shift ;;
      --skip-deps) SKIP_DEPS_CHECK=1; shift ;;
      --auto-install-deps|--install-deps) AUTO_INSTALL_DEPS=1; shift ;;
      --no-auto-install-deps) AUTO_INSTALL_DEPS=0; shift ;;
      --uninstall) MENU_MODE=0; CLI_MODE=1; RUN_ACTION="uninstall"; shift ;;
      --dialog) FORCE_DIALOG=1; _ui_init; shift ;;
      -y|--yes|--non-interactive) ASSUME_YES=1; CLI_MODE=1; shift ;;
      -i|--interactive) MENU_MODE=1; shift ;;
      -q|--quiet) QUIET=1; DEPS_VERBOSE=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知选项: $1 (try --help)" ;;
    esac
  done
  normalize_profile
  # -y implies auto-install when user did not explicitly forbid it
  if [[ "$ASSUME_YES" -eq 1 && "$AUTO_INSTALL_DEPS" -eq -1 ]]; then
    AUTO_INSTALL_DEPS=1
  fi
}

# ═══════════════════════════════════════════════════════════
# Startup dependency self-check
# ═══════════════════════════════════════════════════════════

_is_debian_family() {
  if [[ -f /etc/debian_version ]]; then
    return 0
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    [[ "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]] && return 0
    [[ "${ID_LIKE:-}" == *debian* ]] && return 0
  fi
  return 1
}

_cmd_ok() { command -v "$1" &>/dev/null; }

_bash_major() {
  printf '%s' "${BASH_VERSINFO[0]:-0}"
}

# Collect missing packages for apt hint / auto-install
DEPS_MISSING_HARD=()
DEPS_MISSING_SOFT=()
DEPS_APT_PKGS=()      # union (display)
DEPS_APT_HARD=()      # apt packages for hard cmds
DEPS_APT_SOFT=()      # apt packages for soft cmds
DEPS_NOTES=()
DEPS_HARD_FAIL=0
DEPS_SOFT_FAIL=0

_deps_list_has() {
  # _deps_list_has needle item1 item2 ...
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

_deps_add_apt() {
  local pkg="$1" kind="${2:-any}"
  [[ -n "$pkg" ]] || return 0
  if ! _deps_list_has "$pkg" ${DEPS_APT_PKGS[@]+"${DEPS_APT_PKGS[@]}"}; then
    DEPS_APT_PKGS+=("$pkg")
  fi
  if [[ "$kind" == "hard" ]]; then
    if ! _deps_list_has "$pkg" ${DEPS_APT_HARD[@]+"${DEPS_APT_HARD[@]}"}; then
      DEPS_APT_HARD+=("$pkg")
    fi
  elif [[ "$kind" == "soft" ]]; then
    if ! _deps_list_has "$pkg" ${DEPS_APT_SOFT[@]+"${DEPS_APT_SOFT[@]}"}; then
      DEPS_APT_SOFT+=("$pkg")
    fi
  fi
}

_deps_note() {
  DEPS_NOTES+=("$1")
}

# check_dependencies [strict=1]
# Hard miss → return 1 when strict=1
check_dependencies() {
  local strict="${1:-1}"
  DEPS_MISSING_HARD=()
  DEPS_MISSING_SOFT=()
  DEPS_APT_PKGS=()
  DEPS_APT_HARD=()
  DEPS_APT_SOFT=()
  DEPS_NOTES=()
  DEPS_HARD_FAIL=0
  DEPS_SOFT_FAIL=0

  local hard_fail=0 soft_fail=0
  local status

  _dep_line() {
    # _dep_line KIND CMD PACKAGE DESC
    local kind="$1" cmd="$2" pkg="$3" desc="$4"
    if _cmd_ok "$cmd"; then
      status="${C_GREEN}OK${C_RESET}"
      [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
        printf '  %-12s %-14s %s  %s\n' "$kind" "$cmd" "$status" "${C_DIM}${desc}${C_RESET}"
      return 0
    fi
    if [[ "$kind" == "hard" ]]; then
      hard_fail=1
      DEPS_MISSING_HARD+=("$cmd")
      status="${C_RED}缺${C_RESET}"
      _deps_add_apt "$pkg" hard
    else
      soft_fail=1
      DEPS_MISSING_SOFT+=("$cmd")
      status="${C_YELLOW}缺${C_RESET}"
      [[ -n "$pkg" ]] && _deps_add_apt "$pkg" soft
    fi
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s %s(包: %s)%s\n' \
        "$kind" "$cmd" "$status" "${C_DIM}${desc}${C_RESET}" "$C_DIM" "${pkg:-—}" "$C_RESET"
  }

  if [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]]; then
    printf '\n%s▸ 依赖自检%s\n\n' "$C_BOLD$C_BLUE" "$C_RESET"
    printf '  %-12s %-14s %-6s %s\n' "级别" "命令" "状态" "说明"
    hr
  fi

  if [[ "$(_bash_major)" -ge 4 ]]; then
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s\n' "hard" "bash" "${C_GREEN}OK${C_RESET}" \
        "${C_DIM}${BASH_VERSION%% *} (≥4.0)${C_RESET}"
  else
    hard_fail=1
    DEPS_MISSING_HARD+=("bash>=4")
    _deps_add_apt "bash" hard
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s\n' "hard" "bash" "${C_RED}旧${C_RESET}" \
        "需要 Bash 4+（当前 ${BASH_VERSION:-unknown}）"
  fi

  _dep_line hard python3 python3 "BDP 计算 / 校验 / 诊断"
  _dep_line hard ip      iproute2 "网卡与路由检测"
  _dep_line hard sysctl  procps   "读写内核参数"

  _dep_line soft ss       iproute2 "连接数 / 状态"
  _dep_line soft tc       iproute2 "设置 fq 队列"
  _dep_line soft nproc    coreutils "CPU 核数检测"
  _dep_line soft curl     curl     "测速回退 (Cachefly)"
  _dep_line soft ethtool  ethtool  "网卡 ring/features 报告"
  _dep_line soft modprobe kmod     "加载 tcp_bbr / sch_fq"
  # systemd is large; still listed as soft. Install only when explicitly useful.
  _dep_line soft systemctl systemd "LimitNOFILE / RPS 持久化"
  _dep_line soft speedtest ""      "Ookla 测速（可选，不自动 apt）"

  if [[ ! -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    hard_fail=1
    DEPS_MISSING_HARD+=("/proc/sys")
    _deps_note "/proc/sys 不可读：非 Linux 或容器限制过严（无法 apt 修复）"
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s\n' "hard" "/proc/sys" "${C_RED}缺${C_RESET}" "内核参数接口"
  else
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s\n' "hard" "/proc/sys" "${C_GREEN}OK${C_RESET}" "内核参数接口"
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    _deps_note "当前非 root：自动 apt 安装需要 sudo"
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s  %s\n' "info" "root" "${C_YELLOW}非root${C_RESET}" "写入/装包需提权"
  else
    [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]] && \
      printf '  %-12s %-14s %s\n' "info" "root" "${C_GREEN}OK${C_RESET}"
  fi

  if ! _cmd_ok speedtest; then
    _deps_note "Ookla speedtest 不自动安装（源不统一）；可用 curl 回退或手动装官方 CLI"
  fi
  if ! _cmd_ok systemctl; then
    _deps_note "无 systemctl：NOFILE/RPS 持久化受限；容器环境勿强装完整 systemd"
  fi
  if ! _cmd_ok modprobe; then
    _deps_note "无 modprobe：若 BBR 已编进内核仍可用"
  fi

  DEPS_HARD_FAIL=$hard_fail
  DEPS_SOFT_FAIL=$soft_fail

  if [[ "$DEPS_VERBOSE" -eq 1 && "$QUIET" -eq 0 ]]; then
    hr
    if [[ "$hard_fail" -eq 0 && "$soft_fail" -eq 0 ]]; then
      ok "依赖完整"
    elif [[ "$hard_fail" -eq 0 ]]; then
      ok "硬依赖满足（可选组件有缺失，功能将降级）"
    else
      err "硬依赖缺失: ${DEPS_MISSING_HARD[*]}"
    fi

    if [[ ${#DEPS_MISSING_SOFT[@]} -gt 0 ]]; then
      warn "可选缺失: ${DEPS_MISSING_SOFT[*]}"
    fi

    if [[ ${#DEPS_APT_PKGS[@]} -gt 0 ]]; then
      printf '\n'
      if _is_debian_family; then
        printf '%sDebian/Ubuntu 可安装：%s\n' "$C_BOLD" "$C_RESET"
        printf '  %ssudo apt-get update && sudo apt-get install -y %s%s\n' \
          "$C_CYAN" "${DEPS_APT_PKGS[*]}" "$C_RESET"
        info "启动时默认会询问是否自动安装；-y / --auto-install-deps 可免确认"
      else
        printf '%s请手动安装：%s %s\n' "$C_BOLD" "$C_RESET" "${DEPS_APT_PKGS[*]}"
        info "自动安装目前仅支持 Debian/Ubuntu (apt)"
      fi
    fi

    if [[ ${#DEPS_NOTES[@]} -gt 0 ]]; then
      printf '\n%s说明：%s\n' "$C_BOLD" "$C_RESET"
      local n
      for n in "${DEPS_NOTES[@]}"; do
        info "$n"
      done
    fi
    printf '\n'
  elif [[ "$hard_fail" -eq 1 ]]; then
    err "硬依赖缺失: ${DEPS_MISSING_HARD[*]}"
    if _is_debian_family && [[ ${#DEPS_APT_PKGS[@]} -gt 0 ]]; then
      err "可: apt-get install -y ${DEPS_APT_PKGS[*]}"
    fi
  fi

  if [[ "$strict" -eq 1 && "$hard_fail" -eq 1 ]]; then
    return 1
  fi
  return 0
}

# Filter apt packages that should not be auto-installed
_deps_filter_auto_pkgs() {
  # stdin/args → AUTO_PKGS array
  AUTO_PKGS=()
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    case "$p" in
      # Avoid pulling a full systemd stack into containers by default
      systemd)
        if [[ -d /run/systemd/system ]] || pidof systemd &>/dev/null; then
          AUTO_PKGS+=("$p")
        else
          _deps_note "跳过自动安装 systemd（当前非 systemd 环境）"
        fi
        ;;
      *) AUTO_PKGS+=("$p") ;;
    esac
  done
}

install_apt_packages() {
  # install_apt_packages pkg1 pkg2 ...
  local pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0

  if ! _is_debian_family; then
    warn "非 Debian/Ubuntu，无法自动安装: ${pkgs[*]}"
    return 1
  fi
  if ! _cmd_ok apt-get; then
    warn "未找到 apt-get，无法自动安装"
    return 1
  fi

  local runner=()
  if [[ "$(id -u)" -eq 0 ]]; then
    runner=(env DEBIAN_FRONTEND=noninteractive)
  elif _cmd_ok sudo; then
    runner=(sudo env DEBIAN_FRONTEND=noninteractive)
  else
    warn "需要 root/sudo 才能 apt 安装: ${pkgs[*]}"
    return 1
  fi

  log "正在更新软件包索引 (apt-get update)..."
  if ! "${runner[@]}" apt-get update -qq; then
    warn "apt-get update 失败，仍尝试 install..."
  fi

  log "正在安装: ${pkgs[*]}"
  if "${runner[@]}" apt-get install -y -qq "${pkgs[@]}"; then
    ok "已安装: ${pkgs[*]}"
    hash -r 2>/dev/null || true
    # refresh command cache for current shell
    local p
    for p in "${pkgs[@]}"; do
      true
    done
    return 0
  fi
  err "apt-get install 失败: ${pkgs[*]}"
  return 1
}

# After check_dependencies populated arrays: maybe install, then re-check.
# Returns 0 if hard deps OK after attempt.
ensure_dependencies() {
  local mode="${1:-startup}"  # startup | check-only
  local want_install=0
  local pkgs=()

  # First pass (may print table)
  check_dependencies 0 || true

  if [[ ${#DEPS_APT_PKGS[@]} -eq 0 && "$DEPS_HARD_FAIL" -eq 0 ]]; then
    return 0
  fi

  # Nothing apt can fix (e.g. only /proc/sys)
  if [[ ${#DEPS_APT_PKGS[@]} -eq 0 ]]; then
    [[ "$DEPS_HARD_FAIL" -eq 0 ]]
    return $?
  fi

  if [[ "$AUTO_INSTALL_DEPS" -eq 0 ]]; then
    [[ "$DEPS_HARD_FAIL" -eq 0 ]] && return 0
    return 1
  fi

  if ! _is_debian_family; then
    warn "检测到缺失依赖，但自动安装仅支持 Debian/Ubuntu"
    [[ "$DEPS_HARD_FAIL" -eq 0 ]]
    return $?
  fi

  # Decide which packages: hard always if missing; soft if auto or user agrees
  if [[ ${#DEPS_APT_HARD[@]} -gt 0 ]]; then
    pkgs+=("${DEPS_APT_HARD[@]}")
  fi

  # Soft packages
  if [[ ${#DEPS_APT_SOFT[@]} -gt 0 ]]; then
    if [[ "$AUTO_INSTALL_DEPS" -eq 1 || "$ASSUME_YES" -eq 1 ]]; then
      pkgs+=("${DEPS_APT_SOFT[@]}")
    elif [[ "$AUTO_INSTALL_DEPS" -eq -1 ]] && is_tty; then
      # will ask once for all below
      pkgs+=("${DEPS_APT_SOFT[@]}")
    elif [[ "$DEPS_HARD_FAIL" -eq 1 ]]; then
      # non-tty, only install hard
      :
    fi
  fi

  # Deduplicate pkgs
  local uniq=() p x seen
  for p in "${pkgs[@]+"${pkgs[@]}"}"; do
    seen=0
    for x in "${uniq[@]+"${uniq[@]}"}"; do
      [[ "$x" == "$p" ]] && { seen=1; break; }
    done
    [[ "$seen" -eq 0 ]] && uniq+=("$p")
  done
  pkgs=("${uniq[@]+"${uniq[@]}"}")

  _deps_filter_auto_pkgs "${pkgs[@]+"${pkgs[@]}"}"
  pkgs=("${AUTO_PKGS[@]+"${AUTO_PKGS[@]}"}")

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    [[ "$DEPS_HARD_FAIL" -eq 0 ]]
    return $?
  fi

  # Consent
  if [[ "$AUTO_INSTALL_DEPS" -eq 1 || "$ASSUME_YES" -eq 1 ]]; then
    want_install=1
  elif [[ "$AUTO_INSTALL_DEPS" -eq -1 ]] && is_tty; then
    printf '\n'
    if [[ "$DEPS_HARD_FAIL" -eq 1 ]]; then
      prompt_yes_no "检测到硬依赖缺失，是否用 apt 自动安装: ${pkgs[*]} ？" "y"
    else
      prompt_yes_no "检测到可选依赖缺失，是否用 apt 自动安装: ${pkgs[*]} ？" "y"
    fi
    want_install=$REPLY_YN
  else
    # non-interactive, no -y: only fail if hard missing
    if [[ "$DEPS_HARD_FAIL" -eq 1 ]]; then
      warn "硬依赖缺失且未启用自动安装（加 -y 或 --auto-install-deps）"
      return 1
    fi
    return 0
  fi

  if [[ "$want_install" -ne 1 ]]; then
    if [[ "$DEPS_HARD_FAIL" -eq 1 ]]; then
      warn "已跳过自动安装；硬依赖仍缺失"
      return 1
    fi
    info "已跳过可选依赖安装"
    return 0
  fi

  if ! install_apt_packages "${pkgs[@]}"; then
    [[ "$DEPS_HARD_FAIL" -eq 0 ]]
    return $?
  fi

  # Re-check quietly if was quiet, else show table again
  log "重新检测依赖..."
  local old_v="$DEPS_VERBOSE"
  # brief second table
  DEPS_VERBOSE=1
  check_dependencies 0 || true
  DEPS_VERBOSE="$old_v"

  if [[ "$DEPS_HARD_FAIL" -eq 1 ]]; then
    err "安装后硬依赖仍不满足: ${DEPS_MISSING_HARD[*]}"
    return 1
  fi
  ok "依赖已就绪"
  return 0
}

ensure_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  if command -v sudo &>/dev/null && is_tty; then
    warn "需要 root 权限，正在通过 sudo 提权..."
    exec sudo -E bash "$0" "$@"
  fi
  die "请使用 root 运行: sudo $0"
}

# ═══════════════════════════════════════════════════════════
# Detect (unchanged logic)
# ═══════════════════════════════════════════════════════════

detect_iface() {
  if [[ -n "$IFACE" ]]; then
    ip link show "$IFACE" &>/dev/null || die "网卡不存在: $IFACE"
    return
  fi
  IFACE="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "$IFACE" ]] || IFACE="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}')"
  [[ -n "$IFACE" ]] || die "无法检测主网卡"
}

detect_specs() {
  CPU_CORES="$(nproc 2>/dev/null || echo 1)"
  MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  MEM_GB="$(( (MEM_MB + 512) / 1024 ))"
  [[ "$MEM_GB" -lt 1 ]] && MEM_GB=1

  VIRT="unknown"
  if command -v systemd-detect-virt &>/dev/null; then
    VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  elif [[ -r /sys/class/dmi/id/product_name ]]; then
    VIRT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
  fi

  OS_PRETTY="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME}")"
  fi

  PUBLIC_IP=""
  if [[ -n "${IFACE:-}" ]]; then
    PUBLIC_IP="$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1 || true)"
  fi
  # Prefer public-looking IP from hostname -I if iface is private-only display
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  HOSTNAME_S="$(hostname -s 2>/dev/null || hostname || echo unknown)"
}

pick_tier() {
  if [[ -n "$FORCE_TIER" ]]; then
    TIER="$FORCE_TIER"
    case "$TIER" in small|medium|large) ;; *) die "tier 必须是 small|medium|large" ;; esac
    return
  fi
  if [[ "$CPU_CORES" -le 2 && "$MEM_MB" -le 4096 ]]; then
    TIER="small"
  elif [[ "$CPU_CORES" -le 4 && "$MEM_MB" -le 8192 ]]; then
    TIER="medium"
  else
    TIER="large"
  fi
}

tier_display() {
  case "${1:-$TIER}" in
    small)  echo "Small" ;;
    medium) echo "Medium" ;;
    large)  echo "Large" ;;
    *)      echo "${1:-$TIER}" ;;
  esac
}

tier_default_path() {
  case "${1:-$TIER}" in
    small)  echo 300 ;;
    medium) echo 500 ;;
    large)  echo 1000 ;;
    *)      echo 300 ;;
  esac
}

# ---------- profile (balanced | aggressive) ----------
normalize_profile() {
  local p="${PROFILE:-balanced}"
  p="${p,,}"
  case "$p" in
    balanced|balance|default|safe|stable) PROFILE="balanced" ;;
    aggressive|agg|high|perf|performance) PROFILE="aggressive" ;;
    *) die "profile 必须是 balanced 或 aggressive（当前: ${PROFILE})" ;;
  esac
}

profile_display() {
  case "${PROFILE}" in
    aggressive) printf '%s激进 (aggressive)%s' "$C_YELLOW" "$C_RESET" ;;
    *)          printf '%s均衡 (balanced)%s' "$C_GREEN" "$C_RESET" ;;
  esac
}

# Interactive: pick profile. Sets PROFILE.
prompt_profile_select() {
  local def_choice=1
  [[ "$PROFILE" == "aggressive" ]] && def_choice=2
  printf '\n%s配置风格：%s\n\n' "$C_BOLD" "$C_RESET"
  cat <<EOF
  1. 均衡 balanced ${C_DIM}（推荐 · 2×BDP · 省内存 · 低抖动）${C_RESET}
  2. 激进 aggressive ${C_DIM}（4×BDP · 更大缓冲 · 需充足内存）${C_RESET}

EOF
  info "激进档适合 ≥8GB 内存、路径带宽较高、高并发节点"
  prompt_menu "请选择 [${def_choice}]"
  case "${REPLY_VAL:-$def_choice}" in
    2) PROFILE="aggressive" ;;
    *) PROFILE="balanced" ;;
  esac
  normalize_profile
  printf '  当前风格：%s\n' "$(profile_display)"
}

warn_profile_risks() {
  normalize_profile
  if [[ "$PROFILE" != "aggressive" ]]; then
    return 0
  fi
  warn "激进档会显著提高缓冲上限，多连接时内存占用更高"
  if [[ "${MEM_MB:-0}" -gt 0 && "$MEM_MB" -lt 4096 ]]; then
    warn "当前内存 ${MEM_MB}MB < 4GB，激进档风险较高"
  fi
  if [[ "${MEM_MB:-0}" -gt 0 && "$MEM_MB" -lt 2048 ]]; then
    warn "内存 < 2GB：强烈不建议激进档，可能 OOM"
    if [[ "$ASSUME_YES" -ne 1 ]] && is_tty; then
      prompt_yes_no "仍要继续使用激进档？" "n"
      [[ "$REPLY_YN" -eq 1 ]] || { PROFILE="balanced"; normalize_profile; warn "已回退为均衡档"; }
    fi
  elif [[ "${MEM_MB:-0}" -gt 0 && "$MEM_MB" -lt 8192 ]]; then
    if [[ "$ASSUME_YES" -ne 1 ]] && is_tty && [[ "${MENU_MODE:-0}" -eq 1 ]]; then
      prompt_yes_no "内存不足 8GB，确认使用激进档？" "y"
      if [[ "$REPLY_YN" -ne 1 ]]; then
        PROFILE="balanced"
        normalize_profile
        warn "已回退为均衡档"
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# Speedtest (core logic preserved; UI progress added)
# ═══════════════════════════════════════════════════════════

run_speedtest_core() {
  # Sets ST_*; no progress UI
  ST_DOWN_MBPS=""
  ST_UP_MBPS=""
  ST_METHOD="none"
  ST_OK=0
  local out t size curl_out

  if command -v speedtest &>/dev/null; then
    if out="$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)"; then
      ST_DOWN_MBPS="$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["download"]["bandwidth"]*8/1e6,2))' 2>/dev/null || true)"
      ST_UP_MBPS="$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["upload"]["bandwidth"]*8/1e6,2))' 2>/dev/null || true)"
      if [[ -n "$ST_DOWN_MBPS" && -n "$ST_UP_MBPS" ]]; then
        ST_METHOD="ookla"
        ST_OK=1
        return 0
      fi
    fi
    if out="$(speedtest --accept-license --accept-gdpr 2>/dev/null)"; then
      ST_DOWN_MBPS="$(echo "$out" | awk '/Download:/{print $2; exit}')"
      ST_UP_MBPS="$(echo "$out" | awk '/Upload:/{print $2; exit}')"
      if [[ -n "$ST_DOWN_MBPS" && -n "$ST_UP_MBPS" ]]; then
        ST_METHOD="ookla-text"
        ST_OK=1
        return 0
      fi
    fi
  fi

  curl_out="$(curl -o /dev/null -s -w '%{time_total} %{size_download}' --max-time 30 \
    'http://cachefly.cachefly.net/100mb.test' 2>/dev/null || true)"
  t="$(echo "$curl_out" | awk '{print $1}')"
  size="$(echo "$curl_out" | awk '{print $2}')"
  if [[ -n "$t" && -n "$size" && "$t" != "0" && "$size" -gt 1000000 ]]; then
    ST_DOWN_MBPS="$(python3 -c "print(round($size*8/float('$t')/1e6,2))")"
    ST_UP_MBPS=""
    ST_METHOD="curl-cachefly"
    ST_OK=1
    return 0
  fi
  return 1
}

run_speedtest() {
  # Quiet wrapper for CLI
  if run_speedtest_core; then
    ok "测速完成 (${ST_METHOD}): 下载 ${ST_DOWN_MBPS:-na} Mbps  上传 ${ST_UP_MBPS:-na} Mbps"
    return 0
  fi
  warn "测速失败，将仅使用等级默认参数"
  ST_METHOD="failed"
  ST_OK=0
  return 0
}

run_speedtest_ui() {
  printf '\n%s正在测速...%s\n\n' "$C_BOLD" "$C_RESET"
  info "优先 Ookla speedtest，失败则 curl Cachefly 回退"
  info "注意：机房测速 ≠ 中国客户端真实路径"

  local tmpf
  tmpf="$(mktemp)"
  (
    set +e
    run_speedtest_core
    echo "ST_OK=$ST_OK" >"$tmpf"
    echo "ST_METHOD=$ST_METHOD" >>"$tmpf"
    echo "ST_DOWN_MBPS=$ST_DOWN_MBPS" >>"$tmpf"
    echo "ST_UP_MBPS=$ST_UP_MBPS" >>"$tmpf"
  ) &
  local spid=$!

  # Dual bars: download animates first half of wait, upload second (visual only)
  local pct=0 phase=0
  while kill -0 "$spid" 2>/dev/null; do
    if (( phase == 0 )); then
      progress_bar "$pct" 28 "下载"
      printf '\n'
      progress_bar 0 28 "上传"
      printf '\033[1A'
    else
      progress_bar 100 28 "下载"
      printf '\n'
      progress_bar "$pct" 28 "上传"
      printf '\033[1A'
    fi
    sleep 0.3
    pct=$(( pct + RANDOM % 5 + 2 ))
    if (( pct >= 100 )); then
      if (( phase == 0 )); then
        phase=1
        pct=5
      else
        pct=95
      fi
    fi
  done
  wait "$spid" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$tmpf"
  rm -f "$tmpf"

  progress_bar 100 28 "下载"
  printf '\n'
  progress_bar 100 28 "上传"
  printf '\n\n'

  if [[ "${ST_OK:-0}" -eq 1 ]]; then
    ok "测速完成"
    printf '  下载速度：%s%s Mbps%s\n' "$C_GREEN$C_BOLD" "${ST_DOWN_MBPS:-na}" "$C_RESET"
    printf '  上传速度：%s%s Mbps%s\n' "$C_GREEN$C_BOLD" "${ST_UP_MBPS:-na}" "$C_RESET"
    printf '  方法：%s\n' "$ST_METHOD"
  else
    warn "测速失败，将使用等级默认路径带宽"
    ST_METHOD="failed"
    ST_OK=0
  fi
}

# ═══════════════════════════════════════════════════════════
# Compute / render (logic preserved)
# ═══════════════════════════════════════════════════════════

compute_params() {
  normalize_profile
  detect_cc_capability

  if [[ -z "$CN_RTT_MS" ]]; then
    CN_RTT_MS=200
  fi

  local tier_path_cap tier_origin_cap
  case "$TIER" in
    small)
      tier_path_cap=300
      tier_origin_cap=2000
      SOM_AXCONN=32768
      SYN_BACKLOG=65535
      NETDEV_BACKLOG=16384
      NETDEV_BUDGET=300
      NETDEV_BUDGET_USECS=4000
      BUSY_READ=0
      BUSY_POLL=0
      ;;
    medium)
      tier_path_cap=500
      tier_origin_cap=5000
      SOM_AXCONN=65535
      SYN_BACKLOG=131072
      NETDEV_BACKLOG=32768
      NETDEV_BUDGET=400
      NETDEV_BUDGET_USECS=6000
      BUSY_READ=0
      BUSY_POLL=0
      ;;
    large)
      tier_path_cap=1000
      tier_origin_cap=10000
      SOM_AXCONN=65535
      SYN_BACKLOG=262144
      NETDEV_BACKLOG=100000
      NETDEV_BUDGET=600
      NETDEV_BUDGET_USECS=8000
      BUSY_READ=0
      BUSY_POLL=0
      ;;
  esac

  PATH_MBPS_EFF="$tier_path_cap"
  if [[ -n "$CN_PATH_MBPS" ]]; then
    PATH_MBPS_EFF="$CN_PATH_MBPS"
  elif [[ "$ST_OK" -eq 1 && -n "$ST_DOWN_MBPS" ]]; then
    PATH_MBPS_EFF="$(python3 -c "print(int(min(float('$ST_DOWN_MBPS'), float('$tier_path_cap'))))")"
  fi

  ORIGIN_MBPS_EFF="$tier_origin_cap"
  if [[ "$ST_OK" -eq 1 && -n "$ST_DOWN_MBPS" ]]; then
    ORIGIN_MBPS_EFF="$(python3 -c "print(int(min(max(float('$ST_DOWN_MBPS'), 100), float('$tier_origin_cap'))))")"
  fi

  # --- profile coefficients (formula unchanged: BDP = Mbps * RTT_ms * 125) ---
  local bmax bmin tcp_cap
  if [[ "$PROFILE" == "aggressive" ]]; then
    BDP_HEADROOM=4
    bmin=8388608   # 8MB
    case "$TIER" in
      small)
        bmax=67108864    # 64MB
        tcp_cap=33554432 # 32MB
        UDP_MEM="131072 262144 524288"
        UDP_RMEM_MIN=16384
        UDP_WMEM_MIN=16384
        SOM_AXCONN=65535
        SYN_BACKLOG=131072
        NETDEV_BACKLOG=32768
        NETDEV_BUDGET=400
        NETDEV_BUDGET_USECS=6000
        FILE_MAX=2097152
        ;;
      medium)
        bmax=134217728   # 128MB
        tcp_cap=67108864 # 64MB
        UDP_MEM="262144 524288 1048576"
        UDP_RMEM_MIN=32768
        UDP_WMEM_MIN=32768
        SOM_AXCONN=65535
        SYN_BACKLOG=262144
        NETDEV_BACKLOG=65535
        NETDEV_BUDGET=500
        NETDEV_BUDGET_USECS=8000
        FILE_MAX=2097152
        ;;
      large)
        bmax=268435456    # 256MB
        tcp_cap=134217728 # 128MB
        UDP_MEM="524288 1048576 2097152"
        UDP_RMEM_MIN=65536
        UDP_WMEM_MIN=65536
        SOM_AXCONN=65535
        SYN_BACKLOG=524288
        NETDEV_BACKLOG=250000
        NETDEV_BUDGET=800
        NETDEV_BUDGET_USECS=10000
        FILE_MAX=4194304
        ;;
    esac
    RMEM_DEFAULT=524288
    WMEM_DEFAULT=524288
    TCP_RMEM_DEF=262144
    TCP_WMEM_DEF=262144
    # VPS: still keep busy_poll off (steal/jitter)
    BUSY_READ=0
    BUSY_POLL=0
  else
    # balanced (default) — original coefficients
    BDP_HEADROOM=2
    bmin=4194304   # 4MB
    case "$TIER" in
      small)
        bmax=33554432
        tcp_cap=16777216
        UDP_MEM="65536 131072 262144"
        ;;
      medium)
        bmax=67108864
        tcp_cap=33554432
        UDP_MEM="131072 262144 524288"
        ;;
      large)
        bmax=134217728
        tcp_cap=67108864
        UDP_MEM="262144 524288 1048576"
        ;;
    esac
    UDP_RMEM_MIN=8192
    UDP_WMEM_MIN=8192
    RMEM_DEFAULT=262144
    WMEM_DEFAULT=262144
    TCP_RMEM_DEF=131072
    TCP_WMEM_DEF=131072
    FILE_MAX=1048576
    if [[ "$TIER" == "large" ]]; then
      FILE_MAX=2097152
    fi
  fi

  BDP_BYTES="$(python3 -c "print(int(float('$PATH_MBPS_EFF') * float('$CN_RTT_MS') * 125))")"
  RMEM_MAX="$(python3 -c "v=int('$BDP_BYTES')*int('$BDP_HEADROOM'); print(min(max(v, $bmin), $bmax))")"
  WMEM_MAX="$RMEM_MAX"
  TCP_RMEM_MAX="$(python3 -c "print(min(int('$RMEM_MAX'), $tcp_cap))")"
  TCP_WMEM_MAX="$TCP_RMEM_MAX"

  # udp_mem is in *pages* (~4KiB). Scale to RAM so small VPS cannot reserve multi-GB UDP.
  # Cap max pages ≈ min(tier_table_max, ~12.5% of RAM), keep 1:2:4 ratio.
  scale_udp_mem_to_ram

  # Process FD ceiling: nr_open need not equal file-max; keep a sane per-process cap.
  # (file-max = system-wide; nr_open = per-process hard limit)
  if [[ -z "${NR_OPEN:-}" ]]; then
    if [[ "$FILE_MAX" -gt 1048576 ]]; then
      NR_OPEN=1048576
    else
      NR_OPEN="$FILE_MAX"
    fi
  fi
}

# Mutates UDP_MEM using MEM_MB (pages, 4k assumed for budgeting).
scale_udp_mem_to_ram() {
  local mem_mb="${MEM_MB:-0}"
  if [[ -z "$mem_mb" || "$mem_mb" -le 0 ]]; then
    mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)"
  fi
  # shellcheck disable=SC2034
  UDP_MEM="$(python3 -c "
mem_mb = int('${mem_mb}')
# budget: max UDP pages ≈ 12.5% of RAM (4k pages); floor 16384 pages (~64MB)
ram_pages = max(1, mem_mb * 1024 * 1024 // 4096)
cap = max(16384, ram_pages // 8)
parts = [int(x) for x in '''${UDP_MEM}'''.split()]
if len(parts) != 3:
    print('''${UDP_MEM}''')
else:
    mx = parts[2]
    if mx > cap:
        scale = cap / float(mx)
        parts = [max(4096, int(p * scale)) for p in parts]
        if parts[0] > parts[1]:
            parts[0] = parts[1]
        if parts[1] > parts[2]:
            parts[1] = parts[2]
    print(parts[0], parts[1], parts[2])
")"
}

human_bytes() {
  python3 -c "
v=int('$1')
for u,d in [('GB',1024**3),('MB',1024**2),('KB',1024)]:
    if v >= d:
        print(f'{v/d:.1f}{u}')
        break
else:
    print(f'{v}B')
"
}

_maybe_human_bytes() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '  %s(%s)%s' "$C_DIM" "$(human_bytes "$v")" "$C_RESET"
  fi
}

sysctl_get() {
  sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//' || echo "n/a"
}

render_conf() {
  cat <<EOF
# ===== Auto-generated by hy2-net-auto-tune.sh v${SCRIPT_VERSION} =====
# Host: ${HOSTNAME_S}  IP: ${PUBLIC_IP}  IFACE: ${IFACE}
# OS: ${OS_PRETTY}  Virt: ${VIRT}
# Specs: ${CPU_CORES} vCPU / ${MEM_MB} MB RAM  Tier: ${TIER}
# Speedtest: method=${ST_METHOD} down=${ST_DOWN_MBPS:-na} up=${ST_UP_MBPS:-na} Mbps
# CN path assumption: rtt=${CN_RTT_MS}ms path_mbps=${PATH_MBPS_EFF} (BDP~${BDP_BYTES} bytes)
# Origin TCP sizing reference: ~${ORIGIN_MBPS_EFF} Mbps
# Region: ${REGION_NAME:-default}
# Tuning profile: ${PROFILE} (BDP×${BDP_HEADROOM}, low-jitter Hy2 / CN clients)
# Generated: $(date -Iseconds)

# Queue + congestion (${CC_ALGO}; available: ${CC_AVAILABLE:-unknown})
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC_ALGO}

# TCP proxy-friendly
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.ip_local_port_range = 10240 65535

# Buffers (BDP-aware, capped by tier)
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.ipv4.tcp_rmem = 4096 ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# UDP / Hy2
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN}
net.ipv4.udp_mem = ${UDP_MEM}

# Queues
net.core.somaxconn = ${SOM_AXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}

# Jitter: avoid busy-poll on VPS (CPU steal / noise)
net.core.busy_read = ${BUSY_READ}
net.core.busy_poll = ${BUSY_POLL}

# FD (system-wide vs per-process)
fs.file-max = ${FILE_MAX}
fs.nr_open = ${NR_OPEN}

# Memory pressure (also set in cpu-mem conf if used; same value)
vm.swappiness = 0
EOF
}

backup_existing() {
  local dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  for f in "$CONF_PATH" "$CPU_MEM_CONF_PATH" "${LEGACY_PATHS[@]}" /etc/sysctl.conf; do
    if [[ -f "$f" ]]; then
      cp -a "$f" "$dir/" || true
    fi
  done
  # Snapshot live key values for restore reference
  {
    echo "# live snapshot $(date -Iseconds)"
    for k in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_congestion_control \
             net.core.default_qdisc net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
             net.ipv4.udp_mem fs.file-max vm.swappiness; do
      printf '%s = %s\n' "$k" "$(sysctl_get "$k")"
    done
  } >"$dir/live-sysctl.snapshot"
  echo "$dir"
}

disable_legacy_conflicts() {
  local p
  for p in "${LEGACY_PATHS[@]}"; do
    if [[ -f "$p" && -s "$p" ]]; then
      if grep -qE 'net-tune-pro|CN-proxy latency|hy2-net-auto-tune' "$p" 2>/dev/null \
         || grep -q 'net.core.rmem_max' "$p" 2>/dev/null; then
        if [[ "$p" != "$CONF_PATH" ]]; then
          mv -f "$p" "${p}.disabled-by-hy2-auto-tune"
          log "已禁用旧配置: $p"
        fi
      fi
    fi
  done
}

apply_sysctl() {
  detect_cc_capability
  if [[ "$CC_ALGO" == "bbr2" ]]; then
    modprobe tcp_bbr2 2>/dev/null || modprobe tcp_bbr 2>/dev/null || true
  else
    modprobe tcp_bbr 2>/dev/null || true
  fi
  modprobe sch_fq 2>/dev/null || true
  sysctl --system >"$SYSCTL_LOG" 2>&1 || {
    warn "sysctl --system 有报错，详见 $SYSCTL_LOG"
  }
  # Ensure chosen CC is active even if conf race
  sysctl -w "net.ipv4.tcp_congestion_control=${CC_ALGO}" >/dev/null 2>&1 || true
  if command -v tc &>/dev/null && [[ -n "$IFACE" ]]; then
    tc qdisc replace dev "$IFACE" root fq 2>/dev/null \
      || tc qdisc replace dev "$IFACE" root handle 1: fq 2>/dev/null \
      || warn "无法在 $IFACE 上设置 fq（可忽略）"
  fi
  if [[ "$DO_NIC_TUNE" -eq 1 ]]; then
    apply_nic_rps || warn "网卡 RPS 应用失败（可忽略）"
  fi
}

verify_keys() {
  python3 - "$CONF_PATH" <<'PY'
import re, subprocess, sys
path = sys.argv[1]
ok = fail = 0
with open(path) as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"([^=]+?)\s*=\s*(.+)$", s)
        if not m:
            continue
        key, exp = m.group(1).strip(), " ".join(m.group(2).split())
        try:
            act = subprocess.check_output(["sysctl", "-n", key], text=True).strip()
            act = " ".join(act.split())
        except Exception:
            print(f"ERR  {key}")
            fail += 1
            continue
        if act == exp:
            ok += 1
        else:
            print(f"DIFF {key}: expected={exp} actual={act}")
            fail += 1
print(f"VERIFY ok={ok} diff={fail}")
sys.exit(1 if fail else 0)
PY
}

# ═══════════════════════════════════════════════════════════
# Diff preview / status
# ═══════════════════════════════════════════════════════════

print_param_diff() {
  local cur_rmem cur_wmem cur_tcp_rmem cur_udp cur_bbr cur_qdisc cur_file
  cur_rmem="$(sysctl_get net.core.rmem_max)"
  cur_wmem="$(sysctl_get net.core.wmem_max)"
  cur_tcp_rmem="$(sysctl_get net.ipv4.tcp_rmem)"
  cur_udp="$(sysctl_get net.ipv4.udp_mem)"
  cur_bbr="$(sysctl_get net.ipv4.tcp_congestion_control)"
  cur_qdisc="$(sysctl_get net.core.default_qdisc)"
  cur_file="$(sysctl_get fs.file-max)"

  local new_tcp_rmem="4096 ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}"
  local new_tcp_wmem="4096 ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}"

  printf '\n%s参数变更预览%s\n\n' "$C_BOLD$C_CYAN" "$C_RESET"

  _diff_line "rmem_max" "$cur_rmem" "$RMEM_MAX"
  _diff_line "wmem_max" "$cur_wmem" "$WMEM_MAX"
  _diff_line "tcp_rmem" "$cur_tcp_rmem" "$new_tcp_rmem"
  _diff_line "tcp_wmem" "$(sysctl_get net.ipv4.tcp_wmem)" "$new_tcp_wmem"
  _diff_line "udp_mem" "$cur_udp" "$UDP_MEM"
  _diff_line "tcp_congestion" "$cur_bbr" "${CC_ALGO}"
  _diff_line "default_qdisc" "$cur_qdisc" "fq"
  _diff_line "file-max" "$cur_file" "$FILE_MAX"
  _diff_line "somaxconn" "$(sysctl_get net.core.somaxconn)" "$SOM_AXCONN"
  _diff_line "udp_rmem_min" "$(sysctl_get net.ipv4.udp_rmem_min)" "$UDP_RMEM_MIN"
  printf '\n'
  info "风格=${PROFILE}  ·  BDP×${BDP_HEADROOM}≈$(human_bytes "$BDP_BYTES")×${BDP_HEADROOM}  ·  tier=$(tier_display)  ·  RTT=${CN_RTT_MS}ms  ·  path=${PATH_MBPS_EFF}Mbps"
  if [[ "$PROFILE" == "aggressive" ]]; then
    info "激进档：更大缓冲/队列，请确认内存与并发场景匹配"
  fi
}

_diff_line() {
  local name="$1" old="$2" new="$3"
  if [[ "$old" == "$new" ]]; then
    printf '  %-16s %s%s%s\n' "$name" "$C_DIM" "无变化 ($old)" "$C_RESET"
  else
    printf '  %-16s %s%s%s → %s%s%s\n' \
      "$name" "$C_YELLOW" "$old" "$C_RESET" "$C_GREEN$C_BOLD" "$new" "$C_RESET"
  fi
}

print_server_info_block() {
  cat <<EOF
${C_BOLD}服务器信息：${C_RESET}

  CPU：${CPU_CORES} Core
  内存：${MEM_GB} GB (${MEM_MB} MB)
  系统：${OS_PRETTY}
  虚拟化：${VIRT}
  网卡：${IFACE}
  公网IP：${PUBLIC_IP:-未知}
  主机名：${HOSTNAME_S}
  等级：${C_GREEN}$(tier_display)${C_RESET}${FORCE_TIER:+ (手动)}
  风格：$(profile_display)
EOF
}

print_system_status() {
  box_title "当前系统状态"
  local bbr qdisc rmem wmem fmax conns ss_est
  bbr="$(sysctl_get net.ipv4.tcp_congestion_control)"
  qdisc="$(sysctl_get net.core.default_qdisc)"
  rmem="$(sysctl_get net.core.rmem_max)"
  wmem="$(sysctl_get net.core.wmem_max)"
  fmax="$(sysctl_get fs.file-max)"
  ss_est="$(ss -ant 2>/dev/null | awk 'NR>1 && $1 ~ /ESTAB/ {c++} END{print c+0}')"
  conns="$(ss -ant 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"

  detect_cc_capability 2>/dev/null || true
  local bbr_s q_s
  if [[ "$bbr" == "bbr" || "$bbr" == "bbr2" ]]; then
    bbr_s="${C_GREEN}已启用 (${bbr})${C_RESET}"
  else
    bbr_s="${C_YELLOW}${bbr}${C_RESET}"
  fi
  if [[ "$qdisc" == "fq" ]]; then
    q_s="${C_GREEN}fq${C_RESET}"
  else
    q_s="${C_YELLOW}${qdisc}${C_RESET}"
  fi

  local iface_qdisc
  iface_qdisc="$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 || echo n/a)"

  cat <<EOF

  拥塞控制：     $bbr_s  ${C_DIM}(可用: ${CC_AVAILABLE:-?}, 推荐: ${CC_PREFERRED})${C_RESET}
  default_qdisc：$q_s
  内核：         ${KERNEL_VERSION:-$(uname -r)}
  当前网卡：     ${IFACE}
  网卡 qdisc：   ${iface_qdisc}
  rmem_max：     ${rmem}$(_maybe_human_bytes "$rmem")
  wmem_max：     ${wmem}
  tcp_rmem：     $(sysctl_get net.ipv4.tcp_rmem)
  udp_mem：      $(sysctl_get net.ipv4.udp_mem)
  文件句柄：     ${fmax}
  连接总数：     ${conns}
  ESTAB：        ${ss_est}
  配置文件：     $(_conf_status_line)

EOF
}

_conf_status_line() {
  if [[ -f "$CONF_PATH" ]]; then
    printf '%s存在%s %s' "$C_GREEN" "$C_RESET" "$CONF_PATH"
  else
    printf '%s未安装%s' "$C_YELLOW" "$C_RESET"
  fi
}

print_conf_view() {
  box_title "当前优化配置"
  if [[ ! -f "$CONF_PATH" ]]; then
    warn "未找到配置文件: $CONF_PATH"
    return 1
  fi
  printf '\n%s路径：%s %s\n\n' "$C_BOLD" "$C_RESET" "$CONF_PATH"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^# ]]; then
      printf '%s%s%s\n' "$C_GRAY" "$line" "$C_RESET"
    elif [[ "$line" =~ rmem_max|wmem_max|tcp_rmem|tcp_wmem|udp_mem|congestion|default_qdisc|file-max|somaxconn ]]; then
      printf '%s%s%s\n' "$C_GREEN$C_BOLD" "$line" "$C_RESET"
    elif [[ -n "$line" ]]; then
      printf '%s\n' "$line"
    else
      printf '\n'
    fi
  done <"$CONF_PATH"
}

# ═══════════════════════════════════════════════════════════
# Feature 9: BBR / BBR2 / kernel capability
# ═══════════════════════════════════════════════════════════

detect_cc_capability() {
  KERNEL_VERSION="$(uname -r 2>/dev/null || echo unknown)"
  CC_MODULE_OK=0
  CC_FQ_OK=0
  modprobe tcp_bbr 2>/dev/null || true
  modprobe tcp_bbr2 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true

  CC_AVAILABLE="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  [[ -z "$CC_AVAILABLE" ]] && CC_AVAILABLE="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")"

  # built-in or module both count as OK
  if echo " $CC_AVAILABLE " | grep -qE '[[:space:]]bbr2?[[:space:]]'; then
    CC_MODULE_OK=1
  elif [[ -d /sys/module/tcp_bbr || -d /sys/module/tcp_bbr2 ]]; then
    CC_MODULE_OK=1
  fi
  if lsmod 2>/dev/null | grep -q '^sch_fq\b' \
     || [[ -d /sys/module/sch_fq ]] \
     || [[ "$(sysctl_get net.core.default_qdisc)" == "fq" ]]; then
    CC_FQ_OK=1
  fi

  CC_PREFERRED="cubic"
  if echo " $CC_AVAILABLE " | grep -qE '[[:space:]]bbr2[[:space:]]'; then
    CC_PREFERRED="bbr2"
  elif echo " $CC_AVAILABLE " | grep -qE '[[:space:]]bbr[[:space:]]'; then
    CC_PREFERRED="bbr"
  elif [[ "$CC_MODULE_OK" -eq 1 ]]; then
    CC_PREFERRED="bbr"
    CC_AVAILABLE="${CC_AVAILABLE} bbr"
  fi

  case "${CC_FORCE:-}" in
    bbr|bbr2)
      CC_ALGO="$CC_FORCE"
      if ! echo " $CC_AVAILABLE " | grep -qE "[[:space:]]${CC_ALGO}[[:space:]]"; then
        warn "请求的拥塞控制 ${CC_ALGO} 可能不可用，可用: ${CC_AVAILABLE:-无}"
        if [[ "$CC_ALGO" == "bbr2" ]] && echo " $CC_AVAILABLE " | grep -qE '[[:space:]]bbr[[:space:]]'; then
          warn "回退到 bbr"
          CC_ALGO="bbr"
        fi
      fi
      ;;
    auto|"")
      CC_ALGO="$CC_PREFERRED"
      if [[ "$CC_ALGO" != "bbr" && "$CC_ALGO" != "bbr2" ]]; then
        CC_ALGO="bbr"
      fi
      ;;
    *)
      die "--cc 必须是 auto|bbr|bbr2"
      ;;
  esac
}

print_cc_capability() {
  detect_cc_capability
  printf '\n%s▸ 内核 / 拥塞控制能力%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  内核版本：     %s\n' "$KERNEL_VERSION"
  printf '  可用算法：     %s\n' "${CC_AVAILABLE:-未知}"
  printf '  当前算法：     %s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '  推荐算法：     %s\n' "$CC_PREFERRED"
  printf '  将使用：       %s%s%s\n' "$C_GREEN$C_BOLD" "$CC_ALGO" "$C_RESET"
  printf '  tcp_bbr 模块： %s\n' "$([[ "$CC_MODULE_OK" -eq 1 ]] && echo "${C_GREEN}OK${C_RESET}" || echo "${C_YELLOW}未加载/不可用${C_RESET}")"
  printf '  sch_fq 模块：  %s\n' "$([[ "$CC_FQ_OK" -eq 1 ]] && echo "${C_GREEN}OK${C_RESET}" || echo "${C_YELLOW}未加载/不可用${C_RESET}")"
  local maj min
  maj="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
  min="$(echo "$KERNEL_VERSION" | cut -d. -f2)"
  if [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]]; then
    if (( maj < 4 || (maj == 4 && min < 9) )); then
      warn "内核较旧（<4.9），BBR 可能不可用；升级内核收益通常大于堆缓冲"
    elif (( maj < 5 )); then
      info "内核可用 BBR；若发行版提供 BBR2/BBRv3 可考虑升级"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# Feature 1: Health diagnostics
# ═══════════════════════════════════════════════════════════

_snmp_udp_field() {
  # _snmp_udp_field Udp RcvbufErrors
  local section="$1" field="$2"
  awk -v sec="$section" -v fld="$field" '
    $1==sec":" {
      if (hdr=="") { hdr=$0; next }
      n=split(hdr,h," ")
      for(i=2;i<=n;i++) if(h[i]==fld) { print $i; exit }
    }
  ' /proc/net/snmp 2>/dev/null || echo 0
}

_cpu_steal_pct() {
  # Approximate steal% from /proc/stat first line
  awk '/^cpu / {
    idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i
    steal=$9+0
    if(total>0) printf "%.1f", steal*100/total; else print "0.0"
    exit
  }' /proc/stat 2>/dev/null || echo "0.0"
}

_softnet_drops() {
  # sum of dropped columns in /proc/net/softnet_stat (field 2 = dropped, hex)
  python3 - <<'PY' 2>/dev/null || echo 0
from pathlib import Path
s = 0
p = Path("/proc/net/softnet_stat")
if p.exists():
    for line in p.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            s += int(parts[1], 16)
print(s)
PY
}

_conntrack_info() {
  local cur max pct
  if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
    cur="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"
    max="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)"
  elif [[ -f /proc/sys/net/ipv4/netfilter/ip_conntrack_count ]]; then
    cur="$(cat /proc/sys/net/ipv4/netfilter/ip_conntrack_count 2>/dev/null || echo 0)"
    max="$(cat /proc/sys/net/ipv4/netfilter/ip_conntrack_max 2>/dev/null || echo 0)"
  else
    echo "disabled 0 0 0"
    return
  fi
  pct=0
  if [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
    pct=$(( cur * 100 / max ))
  fi
  echo "enabled $cur $max $pct"
}

print_health_diagnose() {
  box_title "网络健康诊断"
  detect_iface
  detect_specs
  pick_tier
  detect_cc_capability

  local issues=0
  local udp_rcv udp_snd tcp_retrans listen_of soft_drop steal ct_line ct_st ct_cur ct_max ct_pct
  udp_rcv="$(_snmp_udp_field Udp RcvbufErrors)"
  udp_snd="$(_snmp_udp_field Udp SndbufErrors)"
  # TcpExt may be in /proc/net/netstat
  tcp_retrans="$(awk '/^Tcp:/ && NR==2 {print $13; exit}' /proc/net/snmp 2>/dev/null || echo 0)"
  listen_of="$(awk '/ListenOverflows/ {for(i=1;i<=NF;i++) if($i=="ListenOverflows"){getline; print $i; exit}}' /proc/net/netstat 2>/dev/null || echo 0)"
  # simpler ListenOverflows
  if [[ -z "$listen_of" || "$listen_of" == "0" ]]; then
    listen_of="$(awk '
      /^TcpExt:/ && !vals { n=split($0,h," "); getline; for(i=1;i<=n;i++) if(h[i]=="ListenOverflows"){print $i; exit} vals=1}
    ' /proc/net/netstat 2>/dev/null || echo 0)"
  fi
  soft_drop="$(_softnet_drops)"
  steal="$(_cpu_steal_pct)"
  ct_line="$(_conntrack_info)"
  read -r ct_st ct_cur ct_max ct_pct <<<"$ct_line"

  local mem_avail
  mem_avail="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

  printf '\n%s▸ 缓冲 / 协议错误%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  _diag_metric "UDP RcvbufErrors" "$udp_rcv" 100 "缓冲不足/过小，考虑加大 rmem 或 Hy2 侧"
  _diag_metric "UDP SndbufErrors" "$udp_snd" 100 "发送缓冲压力，考虑 wmem / 路径限速"
  _diag_metric "TCP RetransSegs" "$tcp_retrans" 100000 "累计重传（历史值，需结合增长率）"
  _diag_metric "ListenOverflows" "$listen_of" 1 "accept 队列溢出，检查 somaxconn/应用"
  _diag_metric "softnet drops" "$soft_drop" 100 "软中断丢包，检查 netdev_budget/CPU"

  # track issues from thresholds manually for summary
  [[ "${udp_rcv:-0}" =~ ^[0-9]+$ && "$udp_rcv" -ge 100 ]] && issues=$((issues + 1))
  [[ "${udp_snd:-0}" =~ ^[0-9]+$ && "$udp_snd" -ge 100 ]] && issues=$((issues + 1))
  [[ "${listen_of:-0}" =~ ^[0-9]+$ && "$listen_of" -ge 1 ]] && issues=$((issues + 1))
  [[ "${soft_drop:-0}" =~ ^[0-9]+$ && "$soft_drop" -ge 100 ]] && issues=$((issues + 1))

  printf '\n%s▸ 拥塞控制 / 队列%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  local cur_cc cur_q
  cur_cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
  cur_q="$(sysctl_get net.core.default_qdisc)"
  if [[ "$cur_cc" == "bbr" || "$cur_cc" == "bbr2" ]]; then
    printf '  %-22s %s%s%s\n' "拥塞控制" "$C_GREEN" "$cur_cc OK" "$C_RESET"
  else
    printf '  %-22s %s%s (推荐 %s)%s\n' "拥塞控制" "$C_YELLOW" "$cur_cc" "$CC_PREFERRED" "$C_RESET"
    issues=$((issues + 1))
  fi
  if [[ "$cur_q" == "fq" ]]; then
    printf '  %-22s %s%s%s\n' "default_qdisc" "$C_GREEN" "fq OK" "$C_RESET"
  else
    printf '  %-22s %s%s (推荐 fq)%s\n' "default_qdisc" "$C_YELLOW" "$cur_q" "$C_RESET"
    issues=$((issues + 1))
  fi
  printf '  %-22s %s\n' "可用算法" "${CC_AVAILABLE:-?}"
  printf '  %-22s %s\n' "内核" "$KERNEL_VERSION"

  printf '\n%s▸ 虚拟化 / CPU%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  %-22s %s\n' "虚拟化" "$VIRT"
  printf '  %-22s %s%%\n' "CPU steal(累计估)" "$steal"
  if python3 -c "import sys; sys.exit(0 if float('$steal')>=10 else 1)" 2>/dev/null; then
    printf '  %s[!] steal 偏高，VPS 超卖时调大缓冲收益有限%s\n' "$C_YELLOW" "$C_RESET"
    issues=$((issues + 1))
  fi
  printf '  %-22s %s MB\n' "MemAvailable" "$mem_avail"
  if [[ "$mem_avail" =~ ^[0-9]+$ && "$mem_avail" -lt 256 ]]; then
    printf '  %s[!] 可用内存紧张，勿用 aggressive%s\n' "$C_RED" "$C_RESET"
    issues=$((issues + 1))
  fi

  printf '\n%s▸ Conntrack%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  if [[ "$ct_st" == "enabled" ]]; then
    printf '  %-22s %s / %s (%s%%)\n' "使用量" "$ct_cur" "$ct_max" "$ct_pct"
    if [[ "$ct_pct" -ge 80 ]]; then
      printf '  %s[!] conntrack 使用率 ≥80%%，可能比 rmem 先成为瓶颈%s\n' "$C_YELLOW" "$C_RESET"
      issues=$((issues + 1))
    else
      printf '  %s状态正常%s\n' "$C_GREEN" "$C_RESET"
    fi
  else
    printf '  %s未启用 / 不可用%s\n' "$C_DIM" "$C_RESET"
  fi

  printf '\n%s▸ 本脚本配置%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  配置文件： %s\n' "$(_conf_status_line)"
  printf '  rmem_max： %s\n' "$(sysctl_get net.core.rmem_max)"

  printf '\n%s▸ 诊断结论%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
  if [[ "$issues" -eq 0 ]]; then
    ok "未发现明显异常（${issues} issues）"
    info "若 Hy2 仍慢，优先检查 CN 路径 RTT/带宽与 up_mbps/down_mbps"
  else
    warn "发现 ${issues} 项需关注（见上方黄色/红色提示）"
    info "建议：先修 BBR/fq 与 conntrack/NOFILE，再考虑 aggressive"
  fi
  printf '\n'
}

_diag_metric() {
  local name="$1" val="$2" thr="$3" hint="$4"
  val="${val:-0}"
  if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$thr" =~ ^[0-9]+$ ]] && (( val >= thr )); then
    printf '  %-22s %s%s%s  %s%s%s\n' "$name" "$C_YELLOW" "$val" "$C_RESET" "$C_DIM" "$hint" "$C_RESET"
  else
    printf '  %-22s %s%s%s\n' "$name" "$C_GREEN" "$val" "$C_RESET"
  fi
}

action_diagnose() {
  clear_screen
  print_health_diagnose
  print_cc_capability
  printf '\n'
  prompt_yes_no "是否继续查看进程 NOFILE / Hy2 建议？" "y"
  if [[ "$REPLY_YN" -eq 1 ]]; then
    print_nofile_report
    # ensure path params for suggest
    if [[ -z "${PATH_MBPS_EFF:-}" ]]; then
      CN_RTT_MS="${CN_RTT_MS:-200}"
      compute_params 2>/dev/null || true
    fi
    print_hy2_suggestions
  fi
  pause_enter
}

# ═══════════════════════════════════════════════════════════
# Feature 3: Process LimitNOFILE
# ═══════════════════════════════════════════════════════════

# Populate NOFILE_UNITS array with unit names
discover_proxy_units() {
  NOFILE_UNITS=()
  local u
  if ! command -v systemctl &>/dev/null; then
    return 0
  fi
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    NOFILE_UNITS+=("$u")
  done < <(
    systemctl list-units --type=service --all --no-legend 2>/dev/null \
      | awk '{print $1}' \
      | grep -iE 'hysteria|hy2|s-ui|x-ui|sing-box|mihomo|clash|v2ray|xray|nginx|caddy' \
      || true
  )
  # Also unit-files not running
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    local found=0 x
    for x in "${NOFILE_UNITS[@]+"${NOFILE_UNITS[@]}"}"; do
      [[ "$x" == "$u" ]] && found=1 && break
    done
    [[ "$found" -eq 0 ]] && NOFILE_UNITS+=("$u")
  done < <(
    systemctl list-unit-files --type=service --no-legend 2>/dev/null \
      | awk '{print $1}' \
      | grep -iE 'hysteria|hy2|s-ui|x-ui|sing-box' \
      || true
  )
}

print_nofile_report() {
  printf '\n%s▸ 进程 / systemd LimitNOFILE%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  local soft hard
  soft="$(ulimit -Sn 2>/dev/null || echo n/a)"
  hard="$(ulimit -Hn 2>/dev/null || echo n/a)"
  printf '  当前 shell ulimit： soft=%s hard=%s\n' "$soft" "$hard"
  printf '  内核 fs.file-max：  %s\n' "$(sysctl_get fs.file-max)"
  printf '  目标建议：         %s\n' "$NOFILE_TARGET"

  discover_proxy_units
  if [[ ${#NOFILE_UNITS[@]} -eq 0 ]]; then
    info "未发现常见 Hy2/面板 systemd 服务（可手动指定 unit）"
    return 0
  fi

  local u lim
  for u in "${NOFILE_UNITS[@]}"; do
    lim="$(systemctl show "$u" -p LimitNOFILE --value 2>/dev/null || echo n/a)"
    if [[ "$lim" == "infinity" || "$lim" == "18446744073709551615" ]]; then
      printf '  %-28s %s%s%s\n' "$u" "$C_GREEN" "LimitNOFILE=infinity" "$C_RESET"
    elif [[ "$lim" =~ ^[0-9]+$ ]] && (( lim >= NOFILE_TARGET )); then
      printf '  %-28s %s%s%s\n' "$u" "$C_GREEN" "LimitNOFILE=$lim OK" "$C_RESET"
    elif [[ "$lim" =~ ^[0-9]+$ ]]; then
      printf '  %-28s %sLimitNOFILE=%s (建议 ≥%s)%s\n' "$u" "$C_YELLOW" "$lim" "$NOFILE_TARGET" "$C_RESET"
    else
      printf '  %-28s %s%s%s\n' "$u" "$C_DIM" "LimitNOFILE=$lim" "$C_RESET"
    fi
  done
}

fix_unit_nofile() {
  local unit="$1"
  local drop_dir="/etc/systemd/system/${unit}.d"
  local drop_file="${drop_dir}/99-hy2-nofile.conf"
  mkdir -p "$drop_dir"
  cat >"$drop_file" <<EOF
# managed by hy2-net-auto-tune.sh
[Service]
LimitNOFILE=${NOFILE_TARGET}
EOF
  ok "已写入 $drop_file"
}

action_nofile() {
  clear_screen
  box_title "进程 FD / LimitNOFILE"
  print_nofile_report
  printf '\n'
  if [[ ${#NOFILE_UNITS[@]} -eq 0 ]]; then
    pause_enter
    return 0
  fi
  prompt_yes_no "为上述服务写入 LimitNOFILE=${NOFILE_TARGET} drop-in？" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已跳过修复"
    pause_enter
    return 0
  fi
  local u lim
  for u in "${NOFILE_UNITS[@]}"; do
    lim="$(systemctl show "$u" -p LimitNOFILE --value 2>/dev/null || echo 0)"
    if [[ "$lim" == "infinity" || "$lim" == "18446744073709551615" ]]; then
      info "跳过 $u（已是 infinity）"
      continue
    fi
    if [[ "$lim" =~ ^[0-9]+$ ]] && (( lim >= NOFILE_TARGET )); then
      info "跳过 $u（已 ≥ 目标）"
      continue
    fi
    fix_unit_nofile "$u"
  done
  systemctl daemon-reload 2>/dev/null || true
  ok "daemon-reload 完成"
  info "需手动 restart 对应服务后 LimitNOFILE 才生效，例如: systemctl restart <unit>"
  prompt_yes_no "现在尝试 restart 已修改的服务？" "n"
  if [[ "$REPLY_YN" -eq 1 ]]; then
    for u in "${NOFILE_UNITS[@]}"; do
      if [[ -f "/etc/systemd/system/${u}.d/99-hy2-nofile.conf" ]]; then
        if systemctl restart "$u" 2>/dev/null; then
          ok "restart $u"
        else
          warn "restart $u 失败（服务可能未启用）"
        fi
      fi
    done
  fi
  pause_enter
}

cli_nofile_fix() {
  print_nofile_report
  discover_proxy_units
  [[ ${#NOFILE_UNITS[@]} -gt 0 ]] || { warn "无匹配 unit"; return 0; }
  if [[ "$ASSUME_YES" -ne 1 ]] && is_tty; then
    prompt_yes_no "写入 LimitNOFILE drop-in？" "y"
    [[ "$REPLY_YN" -eq 1 ]] || return 0
  fi
  local u lim
  for u in "${NOFILE_UNITS[@]}"; do
    lim="$(systemctl show "$u" -p LimitNOFILE --value 2>/dev/null || echo 0)"
    if [[ "$lim" =~ ^[0-9]+$ ]] && (( lim >= NOFILE_TARGET )); then
      continue
    fi
    [[ "$lim" == "infinity" ]] && continue
    fix_unit_nofile "$u"
  done
  systemctl daemon-reload 2>/dev/null || true
  ok "NOFILE drop-in 已处理"
}

# ═══════════════════════════════════════════════════════════
# Feature 6: Hy2 up/down_mbps suggestions
# ═══════════════════════════════════════════════════════════

print_hy2_suggestions() {
  local path rtt up down
  path="${PATH_MBPS_EFF:-${CN_PATH_MBPS:-}}"
  rtt="${CN_RTT_MS:-200}"
  if [[ -z "$path" ]]; then
    pick_tier 2>/dev/null || true
    path="$(tier_default_path)"
  fi
  # ~90% of path as safe client/server bandwidth cap
  up="$(python3 -c "print(max(10, int(float('$path') * 0.9)))")"
  down="$up"

  printf '\n%s▸ Hysteria2 建议参数（不自动修改配置）%s\n\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  依据：CN 路径约 %s Mbps · RTT %s ms · tier %s · profile %s\n' \
    "$path" "$rtt" "${TIER:-?}" "${PROFILE:-balanced}"
  printf '  %s建议 up_mbps / down_mbps：%s %s%s%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN$C_BOLD" "$up" "$C_RESET"
  info "取路径带宽约 90%；过大易抖动，过小会人为限速"
  info "请按客户端真实带宽取 min(建议值, 客户端带宽)"

  cat <<EOF

${C_DIM}# 示例（server config.yaml 片段）${C_RESET}
bandwidth:
  up: ${up} mbps
  down: ${down} mbps

${C_DIM}# 或部分面板字段${C_RESET}
up_mbps: ${up}
down_mbps: ${down}

EOF

  # Detect common config paths (report only)
  local found=0 f
  for f in \
    /etc/hysteria/config.yaml \
    /etc/hysteria/config.json \
    /etc/hysteria2/config.yaml \
    /opt/hysteria/config.yaml \
    /usr/local/etc/hysteria/config.yaml \
    /etc/s-ui/bin/config.json
  do
    if [[ -f "$f" ]]; then
      printf '  发现配置文件：%s\n' "$f"
      found=1
    fi
  done
  [[ "$found" -eq 0 ]] && info "未自动发现 Hy2 配置文件路径"

  mkdir -p "$HY2_SUGGEST_DIR" 2>/dev/null || true
  local out="${HY2_SUGGEST_DIR}/hy2-bandwidth-suggest.txt"
  cat >"$out" 2>/dev/null <<EOF || true
# generated by hy2-net-auto-tune v${SCRIPT_VERSION}
# $(date -Iseconds)
path_mbps=${path}
rtt_ms=${rtt}
tier=${TIER:-}
profile=${PROFILE:-}
up_mbps=${up}
down_mbps=${down}
EOF
  info "建议已写入: $out"
}

action_hy2_suggest() {
  clear_screen
  box_title "Hy2 带宽建议"
  detect_iface
  detect_specs
  pick_tier
  printf '\n'
  info "将用当前/默认路径参数生成建议（可先自定义优化写入记忆）"
  if [[ -z "$CN_RTT_MS" ]]; then
    prompt_value "中国平均 RTT (ms)" "200" _validate_positive_int
    CN_RTT_MS="$REPLY_VAL"
  fi
  if [[ -z "$CN_PATH_MBPS" ]]; then
    prompt_value "中国路径带宽 (Mbps)" "$(tier_default_path)" _validate_positive_int
    CN_PATH_MBPS="$REPLY_VAL"
  fi
  compute_params
  print_hy2_suggestions
  pause_enter
}

# ═══════════════════════════════════════════════════════════
# Feature 8: NIC RPS / ethtool (optional, conservative)
# ═══════════════════════════════════════════════════════════

_cpu_rps_mask() {
  # Hex mask for first min(nproc, 8) CPUs — simple shared RPS
  local n
  n="$(nproc 2>/dev/null || echo 1)"
  (( n > 8 )) && n=8
  python3 -c "print(format((1<<int('$n'))-1, 'x'))"
}

print_nic_report() {
  printf '\n%s▸ 网卡状态 (%s)%s\n' "$C_BOLD$C_BLUE" "${IFACE:-?}" "$C_RESET"
  [[ -n "$IFACE" ]] || { warn "无网卡"; return 1; }

  local driver queues rps_sample
  driver="$(ethtool -i "$IFACE" 2>/dev/null | awk '/driver:/ {print $2}' || echo n/a)"
  queues="$(ls -d /sys/class/net/"$IFACE"/queues/rx-* 2>/dev/null | wc -l | tr -d ' ')"
  rps_sample="$(cat /sys/class/net/"$IFACE"/queues/rx-0/rps_cpus 2>/dev/null || echo n/a)"

  printf '  驱动：       %s\n' "$driver"
  printf '  RX 队列数：  %s\n' "${queues:-0}"
  printf '  rx-0 rps：   %s\n' "$rps_sample"
  printf '  建议 mask：  %s  (前 min(nproc,8) 核)\n' "$(_cpu_rps_mask)"

  if command -v ethtool &>/dev/null; then
    printf '\n  %sethtool -g (ring)%s\n' "$C_DIM" "$C_RESET"
    ethtool -g "$IFACE" 2>/dev/null | head -12 | sed 's/^/    /' || info "  无法读取 ring"
    printf '\n  %sethtool -k (features 摘要)%s\n' "$C_DIM" "$C_RESET"
    ethtool -k "$IFACE" 2>/dev/null | grep -E 'tcp-segmentation|generic-receive|large-receive|ntuple' | head -8 | sed 's/^/    /' || true
  else
    info "未安装 ethtool，跳过 ring/features 检测"
  fi
  info "云网卡差异大：默认只提供 RPS 建议；应用前请确认非特殊网卡策略"
}

apply_nic_rps() {
  detect_iface
  local mask q
  mask="$(_cpu_rps_mask)"
  [[ -n "$IFACE" ]] || return 1

  for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    [[ -d "$q" ]] || continue
    if [[ -w "$q/rps_cpus" ]]; then
      echo "$mask" >"$q/rps_cpus" 2>/dev/null || true
    fi
    if [[ -w "$q/rps_flow_cnt" ]]; then
      echo 4096 >"$q/rps_flow_cnt" 2>/dev/null || true
    fi
  done
  # XPS for tx queues
  for q in /sys/class/net/"$IFACE"/queues/tx-*; do
    [[ -d "$q" ]] || continue
    if [[ -w "$q/xps_cpus" ]]; then
      echo "$mask" >"$q/xps_cpus" 2>/dev/null || true
    fi
  done

  # Persist via oneshot script + systemd
  mkdir -p "$(dirname "$NIC_TUNE_SCRIPT")"
  cat >"$NIC_TUNE_SCRIPT" <<EOF
#!/usr/bin/env bash
# managed by hy2-net-auto-tune — re-apply RPS/XPS after boot
set -euo pipefail
IFACE="${IFACE}"
MASK="${mask}"
[[ -d /sys/class/net/\$IFACE ]] || exit 0
for q in /sys/class/net/\$IFACE/queues/rx-*; do
  [[ -w "\$q/rps_cpus" ]] && echo "\$MASK" >"\$q/rps_cpus" || true
  [[ -w "\$q/rps_flow_cnt" ]] && echo 4096 >"\$q/rps_flow_cnt" || true
done
for q in /sys/class/net/\$IFACE/queues/tx-*; do
  [[ -w "\$q/xps_cpus" ]] && echo "\$MASK" >"\$q/xps_cpus" || true
done
EOF
  chmod 755 "$NIC_TUNE_SCRIPT"

  if command -v systemctl &>/dev/null; then
    cat >"$NIC_TUNE_SERVICE" <<EOF
[Unit]
Description=Hy2 NIC RPS/XPS tune (hy2-net-auto-tune)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NIC_TUNE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now hy2-nic-rps.service 2>/dev/null || true
  fi
  ok "已应用 RPS/XPS mask=${mask} → ${IFACE}（并尝试开机持久化）"
}

action_nic_tune() {
  clear_screen
  box_title "网卡优化（RPS/XPS · 可选）"
  detect_iface
  detect_specs
  print_nic_report
  printf '\n'
  info "仅设置 RPS/XPS CPU 亲和；不改 ring/coalesce（避免云网卡异常）"
  prompt_yes_no "现在应用 RPS/XPS 并写入开机服务？" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    pause_enter
    return 0
  fi
  apply_nic_rps
  print_nic_report
  pause_enter
}

# ═══════════════════════════════════════════════════════════
# CPU + Memory optimization (conservative, VPS/Hy2 oriented)
# ═══════════════════════════════════════════════════════════

# Sets: VM_SWAPPINESS VM_VFS_CACHE_PRESSURE VM_DIRTY_BG VM_DIRTY_RATIO
#        VM_MIN_FREE_KB VM_ZONE_RECLAIM THP_MODE CPU_GOVERNOR_TARGET
compute_cpu_mem_params() {
  detect_specs 2>/dev/null || true
  normalize_profile 2>/dev/null || true
  local mem_mb="${MEM_MB:-1024}"

  # min_free_kbytes: ~0.8% RAM, floor scales with size (not fixed 64MB — too harsh on 512MB–1GB boxes)
  # clamp absolute: 16MB .. 256MB; also never request below ~kernel watermark on huge RAM
  VM_MIN_FREE_KB="$(python3 -c "
m=int('${mem_mb}')
v=int(m * 1024 * 0.008)          # 0.8% of RAM in KB
lo = 16384                        # 16MB floor
if m >= 2048:
    lo = 32768                    # 32MB on >=2GB
if m >= 4096:
    lo = 65536                    # 64MB on >=4GB
hi = 262144                       # 256MB cap
print(min(max(v, lo), hi))
")"

  if [[ "${PROFILE:-balanced}" == "aggressive" ]]; then
    VM_SWAPPINESS=0
    VM_VFS_CACHE_PRESSURE=40
    VM_DIRTY_BG=3
    VM_DIRTY_RATIO=10
    VM_ZONE_RECLAIM=0
    THP_MODE="madvise"          # avoid always=latency spikes
    CPU_GOVERNOR_TARGET="performance"
  else
    VM_SWAPPINESS=0
    VM_VFS_CACHE_PRESSURE=50
    VM_DIRTY_BG=5
    VM_DIRTY_RATIO=15
    VM_ZONE_RECLAIM=0
    THP_MODE="madvise"
    # prefer performance; fall back to schedutil if applied later
    CPU_GOVERNOR_TARGET="performance"
  fi
}

_read_cpu_governor() {
  local f
  f="$(ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | head -1)"
  if [[ -n "$f" && -r "$f" ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
  else
    echo "n/a"
  fi
}

_read_cpu_gov_available() {
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "n/a"
}

_read_thp() {
  local t cur
  t="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
  cur="$(echo "$t" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
  if [[ -n "$cur" ]]; then
    echo "$cur"
  else
    echo "$t"
  fi
}

print_cpu_report() {
  compute_cpu_mem_params
  local load steal gov av gov_path
  load="$(cat /proc/loadavg 2>/dev/null | awk '{print $1,$2,$3}')"
  steal="$(_cpu_steal_pct 2>/dev/null || echo 0.0)"
  gov="$(_read_cpu_governor)"
  av="$(_read_cpu_gov_available)"

  printf '\n%s▸ CPU 状态%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  逻辑核：     %s\n' "${CPU_CORES:-$(nproc 2>/dev/null || echo ?)}"
  printf '  Loadavg：    %s\n' "${load:-?}"
  printf '  Steal%%：     %s\n' "$steal"
  printf '  Governor：   %s\n' "$gov"
  printf '  可用策略：   %s\n' "$av"
  printf '  目标策略：   %s%s%s\n' "$C_GREEN" "$CPU_GOVERNOR_TARGET" "$C_RESET"
  if [[ "$gov" == "n/a" ]]; then
    info "云 VPS/容器常无法改 governor（无 cpufreq），属正常"
  fi
  if python3 -c "import sys; sys.exit(0 if float('${steal:-0}')>=10 else 1)" 2>/dev/null; then
    warn "steal 偏高：换更高配/更闲节点收益 > 本地 CPU 调参"
  fi
}

print_mem_report() {
  compute_cpu_mem_params
  local mt ma sw thp
  mt="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  ma="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
  sw="$(sysctl_get vm.swappiness)"
  thp="$(_read_thp | head -1)"

  printf '\n%s▸ 内存状态%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
  printf '  MemTotal：       %s MB\n' "$mt"
  printf '  MemAvailable：   %s MB\n' "$ma"
  printf '  swappiness：     %s → 目标 %s\n' "$sw" "$VM_SWAPPINESS"
  printf '  vfs_cache_pressure： %s → 目标 %s\n' "$(sysctl_get vm.vfs_cache_pressure)" "$VM_VFS_CACHE_PRESSURE"
  printf '  dirty_ratio：    %s → 目标 %s\n' "$(sysctl_get vm.dirty_ratio)" "$VM_DIRTY_RATIO"
  printf '  dirty_background_ratio： %s → 目标 %s\n' "$(sysctl_get vm.dirty_background_ratio)" "$VM_DIRTY_BG"
  printf '  min_free_kbytes：%s → 目标 %s\n' "$(sysctl_get vm.min_free_kbytes)" "$VM_MIN_FREE_KB"
  printf '  zone_reclaim：   %s → 目标 %s\n' "$(sysctl_get vm.zone_reclaim_mode)" "$VM_ZONE_RECLAIM"
  printf '  THP：            %s → 目标 %s\n' "$thp" "$THP_MODE"
  printf '  配置文件：       %s\n' "$CPU_MEM_CONF_PATH"
  if [[ -f "$CPU_MEM_CONF_PATH" ]]; then
    printf '                   %s已安装%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '                   %s未安装%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

render_cpu_mem_conf() {
  compute_cpu_mem_params
  cat <<EOF
# ===== hy2-net-auto-tune CPU/Memory v${SCRIPT_VERSION} =====
# Profile: ${PROFILE:-balanced}  RAM: ${MEM_MB:-?}MB  Host: ${HOSTNAME_S:-?}
# Generated: $(date -Iseconds)
# Conservative proxy-oriented defaults (not desktop/gaming ultra)

# --- Memory ---
vm.swappiness = ${VM_SWAPPINESS}
vm.vfs_cache_pressure = ${VM_VFS_CACHE_PRESSURE}
vm.dirty_background_ratio = ${VM_DIRTY_BG}
vm.dirty_ratio = ${VM_DIRTY_RATIO}
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
vm.zone_reclaim_mode = ${VM_ZONE_RECLAIM}
# Avoid remote NUMA reclaim thrash on multi-socket (usually no-op on VPS)

# page cache reclaim a bit friendlier for network bursts
vm.page-cluster = 0

# --- Light CPU/sched (safe subset) ---
# Disable NUMA balancing migration noise when present
kernel.numa_balancing = 0
EOF
}

apply_cpu_governor() {
  compute_cpu_mem_params
  local gov="$CPU_GOVERNOR_TARGET" cpu f avail applied=0
  avail="$(_read_cpu_gov_available)"
  if [[ "$avail" == "n/a" ]]; then
    info "系统无 cpufreq governor 接口，跳过 CPU 频率策略"
    return 0
  fi
  # fallback if performance not available
  if ! echo " $avail " | grep -q " ${gov} "; then
    if echo " $avail " | grep -q " schedutil "; then
      gov="schedutil"
      warn "无 performance，回退 governor=$gov"
    elif echo " $avail " | grep -q " ondemand "; then
      gov="ondemand"
      warn "无 performance，回退 governor=$gov"
    else
      warn "无可用目标 governor（$avail），跳过"
      return 0
    fi
  fi

  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    f="$cpu/cpufreq/scaling_governor"
    if [[ -w "$f" ]]; then
      echo "$gov" >"$f" 2>/dev/null && applied=1 || true
    fi
    # intel_pstate / amd energy preference when present
    if [[ -w "$cpu/cpufreq/energy_performance_preference" ]]; then
      echo performance >"$cpu/cpufreq/energy_performance_preference" 2>/dev/null || true
    fi
  done
  if [[ "$applied" -eq 1 ]]; then
    ok "CPU governor → $gov"
  else
    warn "无法写入 governor（权限或云限制）"
  fi
}

apply_thp_mode() {
  compute_cpu_mem_params
  local mode="$THP_MODE" f
  f=/sys/kernel/mm/transparent_hugepage/enabled
  if [[ -w "$f" ]]; then
    echo "$mode" >"$f" 2>/dev/null && ok "THP enabled → $mode" || warn "无法设置 THP"
  else
    info "THP 接口不可写，跳过"
  fi
  f=/sys/kernel/mm/transparent_hugepage/defrag
  if [[ -w "$f" ]]; then
    # defer is gentler than always
    echo defer >"$f" 2>/dev/null || echo madvise >"$f" 2>/dev/null || true
  fi
}

install_cpu_mem_runtime() {
  compute_cpu_mem_params
  mkdir -p "$(dirname "$CPU_MEM_RUNTIME_SCRIPT")"
  cat >"$CPU_MEM_RUNTIME_SCRIPT" <<EOF
#!/usr/bin/env bash
# managed by hy2-net-auto-tune — re-apply CPU governor + THP after boot
set -euo pipefail
GOV="${CPU_GOVERNOR_TARGET}"
THP="${THP_MODE}"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  f="\$cpu/cpufreq/scaling_governor"
  if [[ -w "\$f" ]]; then
    avail=\$(cat "\$cpu/cpufreq/scaling_available_governors" 2>/dev/null || true)
    g="\$GOV"
    if [[ -n "\$avail" ]] && ! echo " \$avail " | grep -q " \$g "; then
      echo "\$avail" | grep -q schedutil && g=schedutil || true
    fi
    echo "\$g" >"\$f" 2>/dev/null || true
  fi
  [[ -w "\$cpu/cpufreq/energy_performance_preference" ]] && \
    echo performance >"\$cpu/cpufreq/energy_performance_preference" 2>/dev/null || true
done
if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  echo "\$THP" >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi
if [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]]; then
  echo defer >/sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
fi
EOF
  chmod 755 "$CPU_MEM_RUNTIME_SCRIPT"

  if command -v systemctl &>/dev/null; then
    cat >"$CPU_MEM_RUNTIME_SERVICE" <<EOF
[Unit]
Description=Hy2 CPU/Memory runtime tune (hy2-net-auto-tune)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${CPU_MEM_RUNTIME_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now hy2-cpu-mem-runtime.service 2>/dev/null || true
  fi
}

apply_cpu_mem_sysctl() {
  local body
  body="$(render_cpu_mem_conf)"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    echo "$body"
    return 0
  fi
  if [[ -f "$CPU_MEM_CONF_PATH" ]]; then
    local bdir
    bdir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir"
    cp -a "$CPU_MEM_CONF_PATH" "$bdir/" 2>/dev/null || true
  fi
  printf '%s\n' "$body" >"$CPU_MEM_CONF_PATH"
  chmod 644 "$CPU_MEM_CONF_PATH"
  ok "已写入 $CPU_MEM_CONF_PATH"
  sysctl -p "$CPU_MEM_CONF_PATH" >/tmp/hy2-cpu-mem-sysctl.log 2>&1 || {
    warn "部分 vm/kernel 参数可能不受支持，详见 /tmp/hy2-cpu-mem-sysctl.log"
  }
}

# do_cpu=1 do_mem=1
apply_cpu_mem_tune() {
  local do_cpu="${1:-1}" do_mem="${2:-1}"
  detect_iface 2>/dev/null || true
  detect_specs
  compute_cpu_mem_params

  if [[ "$do_mem" -eq 1 ]]; then
    apply_cpu_mem_sysctl
    apply_thp_mode
  elif [[ "$do_cpu" -eq 1 ]]; then
    # light sysctl for numa_balancing only
    sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
  fi
  if [[ "$do_cpu" -eq 1 ]]; then
    apply_cpu_governor
  fi
  # runtime persist for governor+thp
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    install_cpu_mem_runtime
  fi
  ok "CPU/内存优化步骤完成（profile=${PROFILE}）"
}

action_cpu_tune() {
  clear_screen
  box_title "CPU 优化"
  detect_specs
  print_cpu_report
  printf '\n'
  info "将尝试: governor=performance（可回退 schedutil）+ 开机持久化"
  info "不做: isolcpus / 关超线程 / 深度 C-state（云主机风险高）"
  prompt_yes_no "应用 CPU 优化？" "y"
  [[ "$REPLY_YN" -eq 1 ]] || { warn "已取消"; pause_enter; return 0; }
  # CPU path still writes light sysctl (numa_balancing) via conf if mem conf ok
  apply_cpu_governor
  # ensure numa_balancing line exists: merge into conf without full mem retune if conf missing
  if [[ ! -f "$CPU_MEM_CONF_PATH" ]]; then
    apply_cpu_mem_sysctl
  else
    sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
  fi
  install_cpu_mem_runtime
  print_cpu_report
  pause_enter
}

action_mem_tune() {
  clear_screen
  box_title "内存优化"
  detect_specs
  print_mem_report
  printf '\n'
  info "将设置: swappiness/dirty/min_free/THP=madvise 等（写入 ${CPU_MEM_CONF_PATH}）"
  info "不做: 强杀缓存 drop_caches、zram 一键（需按机器定制）"
  prompt_yes_no "应用内存优化？" "y"
  [[ "$REPLY_YN" -eq 1 ]] || { warn "已取消"; pause_enter; return 0; }
  apply_cpu_mem_sysctl
  apply_thp_mode
  install_cpu_mem_runtime
  print_mem_report
  pause_enter
}

action_cpu_mem_tune() {
  clear_screen
  box_title "CPU + 内存优化"
  detect_specs
  print_cpu_report
  print_mem_report
  printf '\n'
  prompt_profile_select 2>/dev/null || true
  compute_cpu_mem_params
  printf '  将使用风格：%s  min_free=%s KB  THP=%s  gov=%s\n' \
    "$PROFILE" "$VM_MIN_FREE_KB" "$THP_MODE" "$CPU_GOVERNOR_TARGET"
  prompt_yes_no "一并应用 CPU + 内存优化？" "y"
  [[ "$REPLY_YN" -eq 1 ]] || { warn "已取消"; pause_enter; return 0; }
  apply_cpu_mem_tune 1 1
  print_cpu_report
  print_mem_report
  pause_enter
}

cli_cpu_mem_tune() {
  local do_cpu="$1" do_mem="$2"
  detect_iface 2>/dev/null || true
  detect_specs
  compute_cpu_mem_params
  [[ "$do_cpu" -eq 1 ]] && print_cpu_report
  [[ "$do_mem" -eq 1 ]] && print_mem_report
  if [[ "$DRY_RUN" -eq 1 ]]; then
    hr
    render_cpu_mem_conf
    ok "Dry-run：未写入"
    return 0
  fi
  if [[ "$ASSUME_YES" -ne 1 ]] && is_tty; then
    prompt_yes_no "确认应用 CPU/内存优化？" "y"
    [[ "$REPLY_YN" -eq 1 ]] || die "已取消"
  fi
  apply_cpu_mem_tune "$do_cpu" "$do_mem"
}

# ═══════════════════════════════════════════════════════════
# Apply pipeline
# ═══════════════════════════════════════════════════════════

reset_runtime_speed() {
  ST_DOWN_MBPS=""
  ST_UP_MBPS=""
  ST_METHOD="skipped"
  ST_OK=0
}

prepare_profile() {
  # Uses global CN_*, FORCE_TIER, DO_SPEEDTEST, ST_*
  detect_iface
  detect_specs
  pick_tier
  if [[ "$DO_SPEEDTEST" -eq 1 ]]; then
    if [[ "$MENU_MODE" -eq 1 || -t 1 ]]; then
      run_speedtest_ui
    else
      run_speedtest
    fi
  fi
  compute_params
}

do_write_and_apply() {
  local conf_body bdir
  conf_body="$(render_conf)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "Dry-run：不写入文件"
    printf '%s\n' "$conf_body"
    print_hy2_suggestions
    return 0
  fi

  printf '\n'
  log "备份现有配置..."
  bdir="$(backup_existing)"
  ok "备份 → $bdir"

  disable_legacy_conflicts
  printf '%s\n' "$conf_body" >"$CONF_PATH"
  chmod 644 "$CONF_PATH"
  ok "已写入 $CONF_PATH"

  if ! grep -qE '^\s*net\.ipv4\.tcp_congestion_control\s*=' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control=${CC_ALGO}" >>/etc/sysctl.conf
    info "已向 /etc/sysctl.conf 追加 ${CC_ALGO}"
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    log "应用 sysctl..."
    apply_sysctl
    if verify_keys; then
      ok "校验通过：配置已生效"
    else
      warn "部分键值不一致（见上方 DIFF）"
    fi
  else
    ok "仅写入配置，未执行 sysctl --system"
  fi

  # Feature 6: always show Hy2 suggestions after a successful plan/write
  print_hy2_suggestions
}

confirm_and_apply_flow() {
  print_param_diff
  if [[ "$SHOW_CONF_PREVIEW" -eq 1 && "$QUIET" -eq 0 ]]; then
    hr
    printf '%s配置预览（节选）%s\n' "$C_BOLD" "$C_RESET"
    render_conf | grep -E '^(net\.|fs\.|vm\.|# CN|# Specs|# Speedtest)' | head -40
    hr
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    do_write_and_apply
    return 0
  fi

  prompt_yes_no "确认应用以上优化？" "y"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    return 1
  fi
  do_write_and_apply
  printf '\n'
  ok "优化完成"
}

# ═══════════════════════════════════════════════════════════
# Menu actions
# ═══════════════════════════════════════════════════════════

menu_home_header() {
  clear_screen
  cat <<EOF
${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════╗
║          Hy2 Network Auto Tune Pro          ║
║        中国优化 · Hysteria2 调优工具         ║
║                 v${SCRIPT_VERSION}                        ║
╚══════════════════════════════════════════════╝${C_RESET}

EOF
  print_server_info_block
  printf '\n'
  hr
  cat <<EOF

  ${C_GREEN}1.${C_RESET} 一键自动优化 ${C_DIM}（推荐 · 可选均衡/激进）${C_RESET}
  ${C_GREEN}2.${C_RESET} 自动优化 + 网络测速
  ${C_GREEN}3.${C_RESET} 自定义优化
  ${C_GREEN}8.${C_RESET} 激进一键优化 ${C_DIM}（aggressive · 高吞吐）${C_RESET}
  ${C_BLUE}4.${C_RESET} 查看当前系统状态
  ${C_BLUE}5.${C_RESET} 查看当前优化参数
  ${C_BLUE}9.${C_RESET} 网络健康诊断 ${C_DIM}（缓冲/BBR/steal/conntrack）${C_RESET}
  ${C_BLUE}10.${C_RESET} Hy2 带宽建议 ${C_DIM}（up/down_mbps）${C_RESET}
  ${C_BLUE}11.${C_RESET} 进程 LimitNOFILE 检测/修复
  ${C_BLUE}12.${C_RESET} 网卡 RPS/XPS 优化 ${C_DIM}（可选）${C_RESET}
  ${C_BLUE}13.${C_RESET} 依赖自检 ${C_DIM}（命令/软件包）${C_RESET}
  ${C_BLUE}14.${C_RESET} CPU 优化 ${C_DIM}（governor / 调度）${C_RESET}
  ${C_BLUE}15.${C_RESET} 内存优化 ${C_DIM}（vm.* / THP）${C_RESET}
  ${C_BLUE}16.${C_RESET} CPU + 内存一并优化
  ${C_YELLOW}6.${C_RESET} 恢复历史备份
  ${C_YELLOW}7.${C_RESET} 卸载优化配置
  ${C_RED}0.${C_RESET} 退出

EOF
}

action_one_click() {
  clear_screen
  box_title "一键自动优化"
  printf '\n'
  log "检测 CPU / 内存 / 网卡..."
  reset_runtime_speed
  DO_SPEEDTEST=0
  CN_RTT_MS="${CN_RTT_MS:-200}"
  CN_PATH_MBPS=""
  FORCE_TIER=""
  PROFILE="balanced"
  REGION_NAME="auto"
  detect_iface
  detect_specs
  pick_tier

  prompt_profile_select
  warn_profile_risks
  compute_params

  printf '\n'
  ok "检测完成"
  printf '\n'
  printf '  服务器等级：%s%s%s\n' "$C_GREEN$C_BOLD" "$(tier_display)" "$C_RESET"
  printf '  配置风格：  %s\n' "$(profile_display)"
  printf '\n  %s推荐参数：%s\n\n' "$C_BOLD" "$C_RESET"
  printf '  中国 RTT：   %s ms\n' "$CN_RTT_MS"
  printf '  路径带宽：   %s Mbps\n' "$PATH_MBPS_EFF"
  printf '  BDP 倍数：   ×%s\n' "$BDP_HEADROOM"
  printf '  rmem_max：   %s (%s)\n' "$RMEM_MAX" "$(human_bytes "$RMEM_MAX")"
  printf '  网卡：       %s\n' "$IFACE"

  APPLY=1
  DRY_RUN=0
  confirm_and_apply_flow || true
  pause_enter
}

action_auto_speedtest() {
  clear_screen
  box_title "自动优化 + 网络测速"
  printf '\n'
  reset_runtime_speed
  DO_SPEEDTEST=1
  CN_RTT_MS="${CN_RTT_MS:-200}"
  CN_PATH_MBPS=""
  FORCE_TIER=""
  PROFILE="balanced"
  REGION_NAME="auto+speedtest"
  detect_iface
  detect_specs
  pick_tier

  prompt_profile_select
  warn_profile_risks

  run_speedtest_ui
  compute_params

  printf '\n'
  printf '  服务器等级：%s%s%s\n' "$C_GREEN$C_BOLD" "$(tier_display)" "$C_RESET"
  printf '  配置风格：  %s\n' "$(profile_display)"
  printf '  推荐路径带宽：%s%s Mbps%s\n' "$C_GREEN$C_BOLD" "$PATH_MBPS_EFF" "$C_RESET"
  printf '  中国 RTT：%s ms（可在「自定义优化」中修改）\n' "$CN_RTT_MS"
  printf '  BDP 倍数：×%s  →  rmem_max=%s\n' "$BDP_HEADROOM" "$(human_bytes "$RMEM_MAX")"

  APPLY=1
  DRY_RUN=0
  confirm_and_apply_flow || true
  pause_enter
}

action_custom() {
  clear_screen
  box_title "自定义优化"
  printf '\n%s请选择服务器地区：%s\n\n' "$C_BOLD" "$C_RESET"
  cat <<EOF
  1. 洛杉矶 (LA)
  2. 圣何塞 (SJ)
  3. 西雅图 (SEA)
  4. 东京 (NRT)
  5. 新加坡 (SIN)
  6. 香港 (HKG)
  7. 自定义
  0. 返回

EOF
  prompt_menu "请输入"
  local choice="$REPLY_VAL"
  local def_rtt=200 def_path

  detect_iface
  detect_specs
  pick_tier
  def_path="$(tier_default_path)"

  case "$choice" in
    1) REGION_NAME="Los Angeles"; def_rtt=200; def_path=300 ;;
    2) REGION_NAME="San Jose"; def_rtt=190; def_path=300 ;;
    3) REGION_NAME="Seattle"; def_rtt=200; def_path=300 ;;
    4) REGION_NAME="Tokyo"; def_rtt=60; def_path=500 ;;
    5) REGION_NAME="Singapore"; def_rtt=70; def_path=400 ;;
    6) REGION_NAME="Hong Kong"; def_rtt=40; def_path=500 ;;
    7) REGION_NAME="Custom"; def_rtt=200; def_path="$(tier_default_path)" ;;
    0) return 0 ;;
    *) warn "无效选择"; pause_enter; return 0 ;;
  esac

  printf '\n%s地区：%s %s\n' "$C_BOLD" "$C_RESET" "$REGION_NAME"
  info "等级 $(tier_display) 默认路径参考 ${def_path} Mbps"

  prompt_value "请输入中国平均 RTT (ms)" "$def_rtt" _validate_positive_int
  CN_RTT_MS="$REPLY_VAL"

  prompt_value "请输入中国路径带宽 (Mbps)" "$def_path" _validate_positive_int
  CN_PATH_MBPS="$REPLY_VAL"

  printf '\n'
  prompt_yes_no "是否运行服务器测速辅助校验？" "n"
  DO_SPEEDTEST="$REPLY_YN"

  printf '\n%s容量等级:%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. 自动 (%s)\n  2. small\n  3. medium\n  4. large\n\n' "$(tier_display)"
  prompt_menu "请选择 [1]"
  case "${REPLY_VAL:-1}" in
    2) FORCE_TIER="small" ;;
    3) FORCE_TIER="medium" ;;
    4) FORCE_TIER="large" ;;
    *) FORCE_TIER="" ;;
  esac

  prompt_profile_select
  warn_profile_risks

  reset_runtime_speed
  pick_tier
  if [[ "$DO_SPEEDTEST" -eq 1 ]]; then
    run_speedtest_ui
  fi
  # User-specified path must win after speedtest
  compute_params

  printf '\n'
  ok "参数已生成"
  printf '  地区：%s  等级：%s  风格：%s  RTT：%sms  路径：%sMbps  BDP×%s\n' \
    "$REGION_NAME" "$(tier_display)" "$PROFILE" "$CN_RTT_MS" "$PATH_MBPS_EFF" "$BDP_HEADROOM"

  APPLY=1
  DRY_RUN=0
  confirm_and_apply_flow || true
  pause_enter
}

action_status() {
  clear_screen
  detect_iface
  detect_specs
  pick_tier
  print_system_status
  pause_enter
}

action_view_conf() {
  clear_screen
  print_conf_view || true
  pause_enter
}

list_backups() {
  # Fills BACKUP_LIST array (newest first)
  BACKUP_LIST=()
  [[ -d "$BACKUP_ROOT" ]] || return 0
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && BACKUP_LIST+=("$d")
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
}

action_restore() {
  clear_screen
  box_title "备份恢复中心"
  list_backups
  printf '\n'
  if [[ ${#BACKUP_LIST[@]} -eq 0 ]]; then
    warn "未发现备份（目录: $BACKUP_ROOT）"
    pause_enter
    return 0
  fi

  printf '%s发现备份：%s\n\n' "$C_BOLD" "$C_RESET"
  local i=1
  for d in "${BACKUP_LIST[@]}"; do
    printf '  %s%d.%s %s\n' "$C_GREEN" "$i" "$C_RESET" "$d"
    i=$((i + 1))
  done
  printf '  %s0.%s 返回\n\n' "$C_RED" "$C_RESET"

  prompt_menu "请选择要恢复的备份"
  local choice="$REPLY_VAL"
  [[ "$choice" == "0" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice < 1 || choice > ${#BACKUP_LIST[@]} )); then
    warn "无效选择"
    pause_enter
    return 0
  fi

  local name="${BACKUP_LIST[$((choice - 1))]}"
  local bdir="${BACKUP_ROOT}/${name}"
  printf '\n'
  log "将恢复备份: $name"
  ls -la "$bdir" 2>/dev/null | head -20 || true
  printf '\n'
  prompt_yes_no "确认恢复该备份？（将覆盖当前相关配置）" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    pause_enter
    return 0
  fi
  prompt_yes_no "二次确认：真的要恢复吗？" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    pause_enter
    return 0
  fi

  # Safety backup of current state first
  local safety
  safety="$(backup_existing)"
  ok "已创建安全备份: $safety"

  local f base
  for f in "$bdir"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      live-sysctl.snapshot) continue ;;
      sysctl.conf)
        cp -a "$f" /etc/sysctl.conf
        ok "恢复 /etc/sysctl.conf"
        ;;
      *.conf)
        if [[ "$base" == "$(basename "$CONF_PATH")" ]] || [[ "$base" == *.conf ]]; then
          cp -a "$f" "/etc/sysctl.d/${base}"
          ok "恢复 /etc/sysctl.d/${base}"
        fi
        ;;
    esac
  done

  apply_sysctl
  ok "恢复完成并已重新加载 sysctl"
  pause_enter
}

action_uninstall() {
  clear_screen
  box_title "卸载优化配置"
  printf '\n'
  if [[ ! -f "$CONF_PATH" ]]; then
    warn "未检测到优化配置: $CONF_PATH"
    pause_enter
    return 0
  fi

  info "将删除: $CONF_PATH"
  info "并尝试恢复最近一次备份中的相关文件"
  printf '\n'
  prompt_yes_no "确认卸载？" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    pause_enter
    return 0
  fi
  prompt_yes_no "二次确认卸载？" "n"
  if [[ "$REPLY_YN" -ne 1 ]]; then
    warn "已取消"
    pause_enter
    return 0
  fi

  local safety
  safety="$(backup_existing)"
  ok "卸载前安全备份: $safety"

  rm -f "$CONF_PATH"
  ok "已删除 $CONF_PATH"
  if [[ -f "$CPU_MEM_CONF_PATH" ]]; then
    rm -f "$CPU_MEM_CONF_PATH"
    ok "已删除 $CPU_MEM_CONF_PATH"
  fi
  if command -v systemctl &>/dev/null; then
    systemctl disable --now hy2-cpu-mem-runtime.service 2>/dev/null || true
    rm -f "$CPU_MEM_RUNTIME_SERVICE" 2>/dev/null || true
  fi
  rm -f "$CPU_MEM_RUNTIME_SCRIPT" 2>/dev/null || true

  # Re-enable disabled legacy if present
  local p
  for p in "${LEGACY_PATHS[@]}"; do
    if [[ -f "${p}.disabled-by-hy2-auto-tune" ]]; then
      mv -f "${p}.disabled-by-hy2-auto-tune" "$p"
      ok "已恢复旧配置: $p"
    fi
  done

  list_backups
  if [[ ${#BACKUP_LIST[@]} -gt 0 ]]; then
    # Prefer backup that is not the safety one just created
    local name bdir f base
    for name in "${BACKUP_LIST[@]}"; do
      bdir="${BACKUP_ROOT}/${name}"
      [[ "$bdir" == "$safety" ]] && continue
      if [[ -f "$bdir/$(basename "$CONF_PATH")" ]] || [[ -f "$bdir/sysctl.conf" ]]; then
        log "从备份恢复: $name"
        for f in "$bdir"/*; do
          [[ -f "$f" ]] || continue
          base="$(basename "$f")"
          case "$base" in
            live-sysctl.snapshot) ;;
            sysctl.conf) cp -a "$f" /etc/sysctl.conf ;;
            99-hy2-net-auto-tune.conf) ;; # do not reinstall what we uninstall
            *.conf) cp -a "$f" "/etc/sysctl.d/${base}" 2>/dev/null || true ;;
          esac
        done
        break
      fi
    done
  fi

  apply_sysctl
  printf '\n'
  ok "卸载完成"
  printf '  系统已恢复至优化前状态（以可用备份为准）\n'
  pause_enter
}

# ═══════════════════════════════════════════════════════════
# Menu loop / CLI batch
# ═══════════════════════════════════════════════════════════

menu_loop() {
  MENU_MODE=1
  detect_iface
  detect_specs
  pick_tier

  while true; do
    # Refresh light facts each loop
    detect_iface
    detect_specs
    pick_tier
    menu_home_header
    prompt_menu "请输入"
    case "$REPLY_VAL" in
      1) action_one_click ;;
      2) action_auto_speedtest ;;
      3) action_custom ;;
      4) action_status ;;
      5) action_view_conf ;;
      6) action_restore ;;
      7) action_uninstall ;;
      8) action_aggressive_one_click ;;
      9) action_diagnose ;;
      10) action_hy2_suggest ;;
      11) action_nofile ;;
      12) action_nic_tune ;;
      13) action_check_deps ;;
      14) action_cpu_tune ;;
      15) action_mem_tune ;;
      16) action_cpu_mem_tune ;;
      0|q|Q|exit)
        printf '\n%s再见。%s\n' "$C_CYAN" "$C_RESET"
        exit 0
        ;;
      *)
        warn "无效选项，请输入 0-16"
        sleep 1
        ;;
    esac
  done
}

action_check_deps() {
  clear_screen
  box_title "依赖自检 / 自动安装"
  DEPS_VERBOSE=1
  # Menu: allow ask/install (respect --no-auto-install-deps)
  if [[ "$AUTO_INSTALL_DEPS" -eq 0 ]]; then
    check_dependencies 0 || true
  else
    ensure_dependencies check-only || true
  fi
  pause_enter
}

action_aggressive_one_click() {
  clear_screen
  box_title "激进一键优化"
  printf '\n'
  info "等同于一键优化 + profile=aggressive（4×BDP，更大 UDP/队列）"
  reset_runtime_speed
  DO_SPEEDTEST=0
  CN_RTT_MS="${CN_RTT_MS:-200}"
  CN_PATH_MBPS=""
  FORCE_TIER=""
  PROFILE="aggressive"
  REGION_NAME="auto-aggressive"
  detect_iface
  detect_specs
  pick_tier
  warn_profile_risks
  compute_params

  printf '\n'
  ok "检测完成"
  printf '\n'
  printf '  服务器等级：%s%s%s\n' "$C_GREEN$C_BOLD" "$(tier_display)" "$C_RESET"
  printf '  配置风格：  %s\n' "$(profile_display)"
  printf '  中国 RTT：   %s ms\n' "$CN_RTT_MS"
  printf '  路径带宽：   %s Mbps\n' "$PATH_MBPS_EFF"
  printf '  BDP 倍数：   ×%s\n' "$BDP_HEADROOM"
  printf '  rmem_max：   %s (%s)\n' "$RMEM_MAX" "$(human_bytes "$RMEM_MAX")"

  APPLY=1
  DRY_RUN=0
  confirm_and_apply_flow || true
  pause_enter
}

cli_batch_apply() {
  MENU_MODE=0
  log "CLI 模式：检测并计算参数..."
  normalize_profile
  detect_iface
  detect_specs
  pick_tier
  detect_cc_capability
  warn_profile_risks
  reset_runtime_speed
  if [[ "$DO_SPEEDTEST" -eq 1 ]]; then
    run_speedtest
  fi
  compute_params

  printf '\n'
  print_server_info_block
  print_cc_capability
  print_param_diff

  if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "Dry-run 完成"
    print_hy2_suggestions
    if [[ "$SHOW_CONF_PREVIEW" -eq 1 && "$QUIET" -eq 0 ]]; then
      hr
      render_conf
    fi
    return 0
  fi

  if [[ "$ASSUME_YES" -ne 1 ]] && is_tty; then
    prompt_yes_no "确认写入并应用？" "y"
    [[ "$REPLY_YN" -eq 1 ]] || die "已取消"
  fi

  do_write_and_apply
  ok "完成"
}

# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════

main() {
  local raw_args=("$@")
  RUN_ACTION=""
  parse_args "$@"

  # --check-deps: allow auto-install; root optional (apt via sudo)
  if [[ "${RUN_ACTION:-}" == "check-deps" ]]; then
    DEPS_VERBOSE=1
    if ensure_dependencies check-only; then
      exit 0
    fi
    exit 1
  fi

  # Startup dependency self-check + optional auto-install
  # (once per process tree; survives sudo -E re-exec)
  if [[ "$SKIP_DEPS_CHECK" -eq 0 && -z "${HY2_DEPS_DONE:-}" ]]; then
    if ! ensure_dependencies startup; then
      die "依赖自检未通过。请安装硬依赖、使用 --auto-install-deps/-y，或 --skip-deps（不推荐）"
    fi
    export HY2_DEPS_DONE=1
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    ensure_root "${raw_args[@]}"
  fi

  case "${RUN_ACTION:-}" in
    status)
      detect_iface; detect_specs; pick_tier
      print_system_status
      print_cc_capability
      exit 0
      ;;
    diagnose)
      detect_iface; detect_specs; pick_tier
      print_health_diagnose
      print_cc_capability
      print_nofile_report
      exit 0
      ;;
    hy2-suggest)
      detect_iface; detect_specs; pick_tier
      CN_RTT_MS="${CN_RTT_MS:-200}"
      compute_params
      print_hy2_suggestions
      exit 0
      ;;
    nofile-fix)
      cli_nofile_fix
      exit 0
      ;;
    nic-tune)
      detect_iface; detect_specs
      print_nic_report
      if [[ "$ASSUME_YES" -eq 1 ]]; then
        apply_nic_rps
      elif is_tty; then
        prompt_yes_no "应用 RPS/XPS？" "y"
        [[ "$REPLY_YN" -eq 1 ]] && apply_nic_rps
      else
        apply_nic_rps
      fi
      exit 0
      ;;
    cpu-tune)
      cli_cpu_mem_tune 1 0
      exit 0
      ;;
    mem-tune)
      cli_cpu_mem_tune 0 1
      exit 0
      ;;
    cpu-mem-tune)
      cli_cpu_mem_tune 1 1
      exit 0
      ;;
    uninstall)
      ASSUME_YES="${ASSUME_YES:-0}"
      action_uninstall
      exit 0
      ;;
  esac

  if [[ "$MENU_MODE" -eq 1 ]]; then
    menu_loop
  elif [[ "$CLI_MODE" -eq 1 ]]; then
    cli_batch_apply
  elif is_tty; then
    menu_loop
  else
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      cli_batch_apply
    else
      die "非交互环境请使用: $0 -y [options]  或  $0 --menu"
    fi
  fi
}

main "$@"
