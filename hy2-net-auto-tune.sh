#!/usr/bin/env bash
# hy2-net-auto-tune.sh
# Auto-detect VPS specs (+ optional speedtest), then apply a CN/Hy2-oriented
# low-jitter sysctl profile for US (e.g. LA) nodes serving mainland China clients.
#
# Usage:
#   hy2-net-auto-tune.sh                 # detect + apply (no speedtest)
#   hy2-net-auto-tune.sh --speedtest     # detect + speedtest + apply
#   hy2-net-auto-tune.sh --dry-run       # show plan only
#   hy2-net-auto-tune.sh --speedtest --cn-rtt 220 --cn-path-mbps 300
#
# Notes:
# - Server-side speedtest measures VPS↔Internet, NOT China↔VPS path quality.
# - China path RTT/bandwidth should be passed via --cn-rtt / --cn-path-mbps when known.
# - Default assumes ~LA + mainland CN: RTT 200ms, path cap auto-derived from speedtest/tier.

set -euo pipefail

SCRIPT_VERSION="1.0.0"
CONF_PATH="/etc/sysctl.d/99-hy2-net-auto-tune.conf"
LEGACY_PATHS=(
  "/etc/sysctl.d/99-net-tune-pro-v3.conf"
)
BACKUP_ROOT="/root/sysctl-backup"
IFACE=""
DO_SPEEDTEST=0
DRY_RUN=0
APPLY=1
CN_RTT_MS=""
CN_PATH_MBPS=""
FORCE_TIER=""   # small|medium|large
QUIET=0

log()  { [[ "$QUIET" -eq 1 ]] || echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
hy2-net-auto-tune.sh — auto VPS profile for Hy2 / CN clients (low jitter)

Options:
  --speedtest          Run server-side speed test (Ookla or curl fallback)
  --dry-run            Detect + compute only; do not write/apply
  --no-apply           Write conf but do not sysctl --system
  --cn-rtt MS          Typical China client RTT to this VPS (default: 200)
  --cn-path-mbps N     Expected China↔VPS usable Mbps (optional; else derived)
  --tier small|medium|large
                       Force capacity tier (else auto from CPU/RAM)
  --iface IFACE        Primary NIC (default: auto)
  --conf PATH          Output sysctl conf path
  -h, --help           Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --speedtest) DO_SPEEDTEST=1; shift ;;
    --dry-run) DRY_RUN=1; APPLY=0; shift ;;
    --no-apply) APPLY=0; shift ;;
    --cn-rtt) CN_RTT_MS="${2:-}"; shift 2 ;;
    --cn-path-mbps) CN_PATH_MBPS="${2:-}"; shift 2 ;;
    --tier) FORCE_TIER="${2:-}"; shift 2 ;;
    --iface) IFACE="${2:-}"; shift 2 ;;
    --conf) CONF_PATH="${2:-}"; shift 2 ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root"
}

# ---------- detect ----------
detect_iface() {
  if [[ -n "$IFACE" ]]; then
    ip link show "$IFACE" &>/dev/null || die "Interface not found: $IFACE"
    return
  fi
  # default route iface
  IFACE="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "$IFACE" ]] || IFACE="$(ip -br link | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}')"
  [[ -n "$IFACE" ]] || die "Cannot detect primary interface"
}

detect_specs() {
  CPU_CORES="$(nproc 2>/dev/null || echo 1)"
  MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  MEM_GB="$(( (MEM_MB + 512) / 1024 ))"
  if [[ "$MEM_GB" -lt 1 ]]; then
    MEM_GB=1
  fi

  VIRT="unknown"
  if command -v systemd-detect-virt &>/dev/null; then
    VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  fi

  OS_PRETTY="unknown"
  if [[ -f /etc/os-release ]]; then
    # Avoid clobbering SCRIPT_VERSION (os-release defines VERSION=...)
    # shellcheck disable=SC1091
    OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME}")"
  fi

  PUBLIC_IP="$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1)"
  HOSTNAME_S="$(hostname -s 2>/dev/null || hostname)"
}

pick_tier() {
  if [[ -n "$FORCE_TIER" ]]; then
    TIER="$FORCE_TIER"
    case "$TIER" in small|medium|large) ;; *) die "tier must be small|medium|large" ;; esac
    return
  fi
  # Heuristic for proxy nodes
  if [[ "$CPU_CORES" -le 2 && "$MEM_MB" -le 4096 ]]; then
    TIER="small"
  elif [[ "$CPU_CORES" -le 4 && "$MEM_MB" -le 8192 ]]; then
    TIER="medium"
  else
    TIER="large"
  fi
}

# ---------- speedtest ----------
# Sets: ST_DOWN_MBPS ST_UP_MBPS ST_METHOD ST_OK
run_speedtest() {
  ST_DOWN_MBPS=""
  ST_UP_MBPS=""
  ST_METHOD="none"
  ST_OK=0

  if command -v speedtest &>/dev/null; then
    log "Running Ookla speedtest (may take ~20–40s)..."
    local out
    if out="$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)"; then
      ST_DOWN_MBPS="$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["download"]["bandwidth"]*8/1e6,2))' 2>/dev/null || true)"
      ST_UP_MBPS="$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["upload"]["bandwidth"]*8/1e6,2))' 2>/dev/null || true)"
      if [[ -n "$ST_DOWN_MBPS" && -n "$ST_UP_MBPS" ]]; then
        ST_METHOD="ookla"
        ST_OK=1
        return
      fi
    fi
    warn "Ookla JSON parse failed; trying human output..."
    if out="$(speedtest --accept-license --accept-gdpr 2>/dev/null)"; then
      ST_DOWN_MBPS="$(echo "$out" | awk '/Download:/{print $2; exit}')"
      ST_UP_MBPS="$(echo "$out" | awk '/Upload:/{print $2; exit}')"
      if [[ -n "$ST_DOWN_MBPS" && -n "$ST_UP_MBPS" ]]; then
        ST_METHOD="ookla-text"
        ST_OK=1
        return
      fi
    fi
  fi

  log "Fallback: curl Cachefly 100MB download estimate..."
  local t size speed
  # time total download of 100MB
  local curl_out
  curl_out="$(curl -o /dev/null -s -w '%{time_total} %{size_download}' --max-time 30 \
    'http://cachefly.cachefly.net/100mb.test' 2>/dev/null || true)"
  t="$(echo "$curl_out" | awk '{print $1}')"
  size="$(echo "$curl_out" | awk '{print $2}')"
  if [[ -n "$t" && -n "$size" && "$t" != "0" && "$size" -gt 1000000 ]]; then
    # Mbps = bytes*8 / time / 1e6
    ST_DOWN_MBPS="$(python3 -c "print(round($size*8/float('$t')/1e6,2))")"
    ST_UP_MBPS=""  # unknown
    ST_METHOD="curl-cachefly"
    ST_OK=1
    return
  fi
  warn "Speedtest failed; will use tier defaults only."
}

# ---------- sizing ----------
# Compute buffer / queue params from tier + optional BDP
compute_params() {
  # Defaults for CN↔US West if not provided
  if [[ -z "$CN_RTT_MS" ]]; then
    CN_RTT_MS=200
  fi

  # Path Mbps used for BDP: prefer user cn-path, else min(speedtest_down, tier_cap), else tier_cap
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
      # only enable mild busy poll on larger boxes
      BUSY_READ=0
      BUSY_POLL=0
      ;;
  esac

  PATH_MBPS_EFF="$tier_path_cap"
  if [[ -n "$CN_PATH_MBPS" ]]; then
    PATH_MBPS_EFF="$CN_PATH_MBPS"
  elif [[ "$ST_OK" -eq 1 && -n "$ST_DOWN_MBPS" ]]; then
    # Server can be multi-Gbps; CN path rarely is. Cap path for BDP by tier, use min.
    PATH_MBPS_EFF="$(python3 -c "print(int(min(float('$ST_DOWN_MBPS'), float('$tier_path_cap'))))")"
  fi

  ORIGIN_MBPS_EFF="$tier_origin_cap"
  if [[ "$ST_OK" -eq 1 && -n "$ST_DOWN_MBPS" ]]; then
    ORIGIN_MBPS_EFF="$(python3 -c "print(int(min(max(float('$ST_DOWN_MBPS'), 100), float('$tier_origin_cap'))))")"
  fi

  # BDP bytes = Mbps * 1e6/8 * RTT_ms/1000 = Mbps * RTT_ms * 125
  # Use path RTT for client-facing sizing; use a bit headroom (2x) and clamp.
  BDP_BYTES="$(python3 -c "print(int(float('$PATH_MBPS_EFF') * float('$CN_RTT_MS') * 125))")"
  # target max buffer: clamp between 4MB and 64MB for small/medium, up to 128MB large
  local bmax
  case "$TIER" in
    small)  bmax=33554432 ;;   # 32MB
    medium) bmax=67108864 ;;   # 64MB
    large)  bmax=134217728 ;;  # 128MB
  esac
  local bmin=4194304  # 4MB

  RMEM_MAX="$(python3 -c "v=int('$BDP_BYTES')*2; print(min(max(v, $bmin), $bmax))")"
  WMEM_MAX="$RMEM_MAX"
  # tcp max slightly lower than core max is fine; use min(rmem_max, 16–64MB tier)
  local tcp_cap
  case "$TIER" in
    small)  tcp_cap=16777216 ;;
    medium) tcp_cap=33554432 ;;
    large)  tcp_cap=67108864 ;;
  esac
  TCP_RMEM_MAX="$(python3 -c "print(min(int('$RMEM_MAX'), $tcp_cap))")"
  TCP_WMEM_MAX="$TCP_RMEM_MAX"

  RMEM_DEFAULT=262144
  WMEM_DEFAULT=262144
  TCP_RMEM_DEF=131072
  TCP_WMEM_DEF=131072

  # udp_mem in pages (~4k). Scale lightly with tier.
  case "$TIER" in
    small)  UDP_MEM="65536 131072 262144" ;;
    medium) UDP_MEM="131072 262144 524288" ;;
    large)  UDP_MEM="262144 524288 1048576" ;;
  esac

  FILE_MAX=1048576
  if [[ "$TIER" == "large" ]]; then
    FILE_MAX=2097152
  fi
}

# ---------- render / apply ----------
render_conf() {
  cat <<EOF
# ===== Auto-generated by hy2-net-auto-tune.sh v${SCRIPT_VERSION} =====
# Host: ${HOSTNAME_S}  IP: ${PUBLIC_IP}  IFACE: ${IFACE}
# OS: ${OS_PRETTY}  Virt: ${VIRT}
# Specs: ${CPU_CORES} vCPU / ${MEM_MB} MB RAM  Tier: ${TIER}
# Speedtest: method=${ST_METHOD} down=${ST_DOWN_MBPS:-na} up=${ST_UP_MBPS:-na} Mbps
# CN path assumption: rtt=${CN_RTT_MS}ms path_mbps=${PATH_MBPS_EFF} (BDP~${BDP_BYTES} bytes)
# Origin TCP sizing reference: ~${ORIGIN_MBPS_EFF} Mbps
# Profile: low-jitter Hy2 / mainland China clients
# Generated: $(date -Iseconds)

# Queue + congestion (BBR should also be set system-wide)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

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
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = ${UDP_MEM}

# Queues
net.core.somaxconn = ${SOM_AXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}

# Jitter: avoid busy-poll on small/medium VPS
net.core.busy_read = ${BUSY_READ}
net.core.busy_poll = ${BUSY_POLL}

# FD
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}

# Memory pressure
vm.swappiness = 0
EOF
}

backup_existing() {
  local dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  for f in "$CONF_PATH" "${LEGACY_PATHS[@]}" /etc/sysctl.conf; do
    if [[ -f "$f" ]]; then
      cp -a "$f" "$dir/" || true
    fi
  done
  echo "$dir"
}

disable_legacy_conflicts() {
  # Prevent double-application of overlapping keys from old pro-v3 file.
  # Keep a disabled copy if present and non-empty.
  local p
  for p in "${LEGACY_PATHS[@]}"; do
    if [[ -f "$p" && -s "$p" ]]; then
      # If it's our previous manual profile or net-tune-pro, rename aside
      if grep -qE 'net-tune-pro|CN-proxy latency|hy2-net-auto-tune' "$p" 2>/dev/null \
         || grep -q 'net.core.rmem_max' "$p" 2>/dev/null; then
        if [[ "$p" != "$CONF_PATH" ]]; then
          mv -f "$p" "${p}.disabled-by-hy2-auto-tune"
          log "Disabled legacy conf: $p -> ${p}.disabled-by-hy2-auto-tune"
        fi
      fi
    fi
  done
}

apply_sysctl() {
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  sysctl --system >/tmp/hy2-net-auto-tune-sysctl.log 2>&1 || {
    warn "sysctl --system reported errors; see /tmp/hy2-net-auto-tune-sysctl.log"
  }
  # Apply fq on primary iface (default_qdisc only affects new devices)
  if command -v tc &>/dev/null && [[ -n "$IFACE" ]]; then
    tc qdisc replace dev "$IFACE" root fq 2>/dev/null \
      || tc qdisc replace dev "$IFACE" root handle 1: fq 2>/dev/null \
      || warn "Could not set fq on $IFACE (non-fatal)"
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

print_summary() {
  cat <<EOF

========== hy2-net-auto-tune summary ==========
Version     : ${SCRIPT_VERSION}
Host        : ${HOSTNAME_S} (${PUBLIC_IP}) iface=${IFACE}
OS / Virt   : ${OS_PRETTY} / ${VIRT}
Specs       : ${CPU_CORES} vCPU, ${MEM_MB} MB RAM
Tier        : ${TIER}
Speedtest   : ${ST_METHOD}  down=${ST_DOWN_MBPS:-na} Mbps  up=${ST_UP_MBPS:-na} Mbps
CN RTT      : ${CN_RTT_MS} ms
CN path Mbps: ${PATH_MBPS_EFF}  (for BDP)
BDP*2 clamp : rmem_max=${RMEM_MAX}  tcp_*mem max=${TCP_RMEM_MAX}
Conf        : ${CONF_PATH}
Dry-run     : ${DRY_RUN}
===============================================

EOF
}

# ---------- main ----------
main() {
  need_root
  detect_iface
  detect_specs
  pick_tier

  ST_DOWN_MBPS=""
  ST_UP_MBPS=""
  ST_METHOD="skipped"
  ST_OK=0
  if [[ "$DO_SPEEDTEST" -eq 1 ]]; then
    run_speedtest
  fi

  compute_params

  log "Detected: ${CPU_CORES} cores, ${MEM_MB}MB RAM, tier=${TIER}, iface=${IFACE}"
  if [[ "$ST_OK" -eq 1 ]]; then
    log "Speedtest (${ST_METHOD}): down=${ST_DOWN_MBPS} Mbps up=${ST_UP_MBPS:-na} Mbps"
  fi
  log "CN assumptions: rtt=${CN_RTT_MS}ms path=${PATH_MBPS_EFF}Mbps -> rmem_max=${RMEM_MAX}"

  local conf_body
  conf_body="$(render_conf)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_summary
    echo "----- conf preview -----"
    echo "$conf_body"
    log "Dry-run: no files written."
    exit 0
  fi

  local bdir
  bdir="$(backup_existing)"
  log "Backup -> $bdir"

  disable_legacy_conflicts

  printf '%s\n' "$conf_body" >"$CONF_PATH"
  chmod 644 "$CONF_PATH"
  log "Wrote $CONF_PATH"

  # Ensure BBR also in sysctl.conf if missing (idempotent)
  if ! grep -qE '^\s*net.ipv4.tcp_congestion_control\s*=' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.tcp_congestion_control=bbr' >>/etc/sysctl.conf
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    log "Applying sysctl..."
    apply_sysctl
    if verify_keys; then
      log "All sysctl keys match conf."
    else
      warn "Some keys differ (see DIFF lines above)."
    fi
    log "qdisc on ${IFACE}: $(tc qdisc show dev "$IFACE" 2>/dev/null | head -1)"
  else
    log "Skipped apply (--no-apply)."
  fi

  print_summary
  cat <<'EOF'
Tips:
  - Re-run with better CN estimates:
      hy2-net-auto-tune.sh --speedtest --cn-rtt 180 --cn-path-mbps 250
  - This does NOT configure Hysteria2 up/down_mbps (set those in s-ui / client).
  - Server speedtest ≠ China client speed; pass --cn-path-mbps when you know it.
EOF
}

main
