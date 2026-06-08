#!/bin/bash
# probe_watch.sh — clean-slate overlay reload with live DIAG capture.
# Run with sudo from the repo root: sudo ./scripts/probe_watch.sh
#
# Fixes the broken dmesg grep (trailing-backslash bug) from debug_session.sh.
# Captures DIAG lines injected by fix_and_debug.sh / debug_session.sh.
# Tries four overlay parameter sets in order; stops on first success.

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
step() { echo -e "\n${CYAN}━━━━  $*  ━━━━${NC}\n"; }

LOG="probe_watch_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "probe_watch.sh  kernel=$(uname -r)  $(date)"
echo ""

# ---------------------------------------------------------------------------
dmesg_genx() {
    # Single-line grep — avoids the trailing-backslash shell bug in debug_session.sh
    dmesg | grep -iE 'genx320|psee|cam[01]_reg|cam[01]_clk|inclk|rstn|eremoteio|power.on|power.off|failed.*sensor|sensor.*failed|DIAG' | tail -40
}

reg_state() {
    local name=$1
    grep -h "" /sys/class/regulator/regulator.*/name 2>/dev/null | \
        grep -c "$name" > /dev/null 2>&1 || true
    for r in /sys/class/regulator/regulator.*/name; do
        [ -f "$r" ] || continue
        N=$(cat "$r" 2>/dev/null)
        [ "$N" = "$name" ] || continue
        DIR=$(dirname "$r")
        STATE=$(cat "$DIR/state" 2>/dev/null || echo "?")
        COUNT=$(cat "$DIR/enable_count" 2>/dev/null || echo "?")
        echo "${name}: state=${STATE} enable_count=${COUNT}"
        return
    done
    echo "${name}: (not found in /sys/class/regulator)"
}

probe_succeeded() {
    for d in 0 1 2 3 4 5; do
        [ -e "/dev/media${d}" ] || continue
        media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320" && return 0
    done
    return 1
}

unload_genx() {
    if dtoverlay -l 2>/dev/null | grep -q genx320; then
        info "Removing loaded genx320 overlay..."
        dtoverlay -r genx320 2>/dev/null || true
        sleep 1
    fi
}

try_overlay() {
    local PARAMS="$1"
    local DESC="$2"

    step "Trying: dtoverlay genx320${PARAMS:+,$PARAMS}  ($DESC)"

    info "Regulator state BEFORE load:"
    reg_state cam0_reg
    reg_state cam1_reg
    echo ""

    dmesg -c > /dev/null 2>&1 || true   # clear ring buffer if allowed
    unload_genx

    info "Loading overlay..."
    dtoverlay "genx320${PARAMS:+,$PARAMS}" 2>&1 || true
    sleep 4   # give driver time to probe (startup-delay-us=900000 + margin)

    info "Regulator state AFTER load:"
    reg_state cam0_reg
    reg_state cam1_reg
    echo ""

    info "DIAG lines from dmesg:"
    dmesg | grep "DIAG" || warn "  No DIAG lines — DIAG logging not in loaded .ko (rebuild needed?)"
    echo ""

    info "All genx320/power dmesg lines:"
    dmesg_genx
    echo ""

    if probe_succeeded; then
        ok "SUCCESS — genx320 probed!"
        return 0
    else
        fail "Probe failed with params: $DESC"
        return 1
    fi
}

# ---------------------------------------------------------------------------
step "Baseline: module and DKMS check"
# ---------------------------------------------------------------------------
if lsmod | grep -q genx320; then
    ok "genx320_driver loaded."
else
    warn "genx320_driver not loaded — attempting modprobe..."
    modprobe genx320-driver 2>&1 || fail "modprobe failed. Run fix_build.sh first."
fi

DKMS_VER=$(dkms status 2>/dev/null | grep psee | awk -F'[,/]' '{print $2}' | tr -d ' ' | head -1)
if [ -n "$DKMS_VER" ]; then
    ok "DKMS: psee_sensor_drivers/${DKMS_VER}"
    # Check if DIAG is in the installed .ko
    KO=$(find /lib/modules/$(uname -r) -name "genx320-driver.ko*" 2>/dev/null | head -1)
    if [ -n "$KO" ]; then
        if strings "$KO" 2>/dev/null | grep -q "DIAG power_on"; then
            ok "DIAG logging confirmed in installed .ko"
        else
            warn "DIAG logging NOT in installed .ko — rebuild needed."
            warn "Run: sudo ./scripts/fix_build.sh  (then re-run this script)"
        fi
    fi
else
    warn "psee_sensor_drivers not in dkms status."
fi

# ---------------------------------------------------------------------------
# Try overlays in order of increasing aggressiveness
# ---------------------------------------------------------------------------
SUCCESS=0

try_overlay "rstn-delay-ms=600,startup-delay-us=900000" "extended delays cam1" && SUCCESS=1

if [ "$SUCCESS" = "0" ]; then
    try_overlay "cam0,rstn-delay-ms=600,startup-delay-us=900000" "extended delays cam0" && SUCCESS=1
fi

if [ "$SUCCESS" = "0" ]; then
    try_overlay "always-on,rstn-delay-ms=600,startup-delay-us=900000" "always-on regulator cam1" && SUCCESS=1
fi

if [ "$SUCCESS" = "0" ]; then
    try_overlay "cam0,always-on,rstn-delay-ms=600,startup-delay-us=900000" "always-on regulator cam0" && SUCCESS=1
fi

# ---------------------------------------------------------------------------
step "Final dmesg snapshot"
# ---------------------------------------------------------------------------
info "All genx320-related dmesg (last 60 lines matching):"
dmesg | grep -iE 'genx320|psee|cam[01]_reg|cam[01]_clk|inclk|rstn|eremoteio|DIAG|power.on|power.off|failed' | tail -60

echo ""
if [ "$SUCCESS" = "1" ]; then
    ok "Sensor probed. Run: ./rp5_setup_v4l.sh"
else
    fail "All attempts failed."
    echo ""
    echo "  DIAG lines above show the exact failure point."
    echo "  If no DIAG lines appeared: run sudo ./scripts/fix_build.sh to rebuild .ko with DIAG logging."
    echo "  If EREMOTEIO persists after DIAG shows 'regulator enabled' and 'inclk enabled':"
    echo "    → Run sudo ./scripts/force_power_test.sh to check hardware."
fi

echo ""
echo "Log: $LOG"
