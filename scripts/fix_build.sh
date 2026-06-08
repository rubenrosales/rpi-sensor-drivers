#!/bin/bash
# fix_build.sh — repair kernel-headers and rebuild the genx320 DKMS module.
# Run with sudo from the repo root: sudo ./scripts/fix_build.sh
#
# Addresses the "Makefile:17 Error 2" failure seen when running fix_and_debug.sh.
# Root cause: missing kernel headers at /lib/modules/$(uname -r)/build.

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
step() { echo -e "\n${CYAN}━━━━  $*  ━━━━${NC}\n"; }

KVER=$(uname -r)
BUILD_DIR="/lib/modules/${KVER}/build"

LOG="fix_build_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "fix_build.sh  kernel=${KVER}  $(date)"
echo ""

# ---------------------------------------------------------------------------
step "1. Kernel headers"
# ---------------------------------------------------------------------------
if [ -d "$BUILD_DIR" ] && [ -f "$BUILD_DIR/Makefile" ]; then
    ok "Kernel headers present: $BUILD_DIR"
else
    warn "Kernel headers missing at $BUILD_DIR"
    info "Installing linux-headers-${KVER} ..."
    if apt-get install -y "linux-headers-${KVER}" 2>&1; then
        ok "Headers installed."
    else
        warn "Exact header package not found. Trying raspberrypi-kernel-headers..."
        apt-get install -y raspberrypi-kernel-headers 2>&1 || true
    fi

    if [ -d "$BUILD_DIR" ] && [ -f "$BUILD_DIR/Makefile" ]; then
        ok "Headers now present: $BUILD_DIR"
    else
        fail "Headers still missing after install attempt."
        echo "  Try manually: sudo apt-get install linux-headers-\$(uname -r)"
        echo "  Or check: ls /usr/src/ | grep \$(uname -r)"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
step "2. drivers/ source directory"
# ---------------------------------------------------------------------------
if [ -d drivers ] && [ -f drivers/Makefile ]; then
    ok "drivers/ present."
else
    warn "drivers/ missing — running make prepare..."
    make prepare 2>&1
    if [ -d drivers ] && [ -f drivers/Makefile ]; then
        ok "drivers/ cloned."
    else
        fail "make prepare failed. Check network access and git."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
step "3. Build psee_sensors (verbose)"
# ---------------------------------------------------------------------------
info "Running: make psee_sensors V=1"
if make psee_sensors V=1 2>&1; then
    ok "Build succeeded."
else
    fail "Build failed — showing last 40 lines:"
    echo ""
    # Re-run non-verbose to get the cleaner error
    make psee_sensors 2>&1 | tail -40 || true
    echo ""
    echo "  Common fixes:"
    echo "  (A) Missing header: sudo apt-get install linux-headers-\$(uname -r)"
    echo "  (B) Stale object files: cd drivers && make clean; cd .."
    echo "  (C) Check gcc: gcc --version"
    exit 1
fi

# ---------------------------------------------------------------------------
step "4. DKMS install"
# ---------------------------------------------------------------------------
info "Installing DKMS module for kernel ${KVER}..."
if dkms install psee_sensor_drivers/1.0.1 -k "${KVER}" 2>&1; then
    ok "DKMS install succeeded."
else
    warn "dkms install reported an error (may already be installed)."
    dkms status 2>/dev/null | grep psee || true
fi

# ---------------------------------------------------------------------------
step "5. Verify module"
# ---------------------------------------------------------------------------
KO_PATH=$(find /lib/modules/"${KVER}" -name "genx320-driver.ko*" 2>/dev/null | head -1)
if [ -n "$KO_PATH" ]; then
    ok "Module found: $KO_PATH"
else
    fail "genx320-driver.ko not found under /lib/modules/${KVER}"
    echo "  Run: sudo dkms status"
fi

echo ""
ok "Done. Next: sudo ./scripts/probe_watch.sh"
echo "Log: $LOG"
