#!/bin/bash
# fix_driver_source.sh — diagnose and fix the genx320 build failure.
# Run with sudo from the repo root: sudo ./scripts/fix_driver_source.sh
#
# Background: previous DIAG injection scripts (fix_and_debug.sh, debug_session.sh)
# inserted dev_info(dev, ...) lines using broad regex patterns.  Those patterns
# matched msleep/clk_prepare_enable/regulator_enable calls in functions OTHER
# than genx320_power_on, where the variable 'dev' does not exist.  GCC rejects
# the file and make exits with Error 2 at Makefile:38.
#
# This script:
#   1. Captures the FIRST real compiler error (not the last-40-lines tail).
#   2. Checks if broken DIAG lines are the cause.
#   3. Fixes genx320.c (restore .orig backup or reclone) and rebuilds.
#   4. Reinstalls the DKMS module.

set -uo pipefail

R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }

KVER=$(uname -r)
SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)

LOG="fix_driver_source_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1
echo "fix_driver_source.sh  kernel=${KVER}  $(date)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "${BOLD}━━━━  STEP 1 / 4   Capture the real first compiler error  ━━━━${N}"
echo ""

BUILD_OUT=$(mktemp /tmp/genx320_build_XXXXXX.txt)
make psee_sensors 2>&1 | tee "$BUILD_OUT" > /dev/null || true

# Show first five genuine GCC error lines (file:line:col: error: ...)
ERRORS=$(grep -E 'error:' "$BUILD_OUT" | head -10)
if [ -n "$ERRORS" ]; then
    fail "Compiler errors found:"
    echo ""
    echo "$ERRORS" | while IFS= read -r e; do
        printf "    %s\n" "$e"
    done
    echo ""
else
    # No GCC errors — maybe a make/linker issue
    warn "No 'error:' lines from GCC. Showing first 30 lines of build output:"
    echo ""
    head -30 "$BUILD_OUT"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}━━━━  STEP 2 / 4   Check DIAG injection damage  ━━━━${N}"
echo ""

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    warn "drivers/genx320.c not found — skipping source check."
else
    DIAG_COUNT=$(grep -c "DIAG" "$SRC" 2>/dev/null || echo 0)
    info "DIAG lines in $SRC: $DIAG_COUNT"

    if [ "$DIAG_COUNT" -gt 0 ]; then
        echo ""
        info "Checking each DIAG line for valid 'dev' variable in scope..."
        echo ""

        # Scan genx320.c: track current function name, flag DIAG lines outside power_on
        python3 - "$SRC" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

current_func = "(global)"
brace_depth  = 0
problems     = []

for i, line in enumerate(lines, 1):
    # Track function entry by looking for static/int/void at column 0
    m = re.match(r'^(static\s+)?(int|void|bool)\s+(\w+)\s*\(', line)
    if m:
        current_func = m.group(3)
        brace_depth  = 0

    brace_depth += line.count('{') - line.count('}')

    if 'DIAG' in line and 'dev_info(dev,' in line:
        # 'dev' is a named parameter only in genx320_power_on and genx320_power_off
        if 'power_on' not in current_func and 'power_off' not in current_func:
            problems.append((i, current_func, line.rstrip()))

if problems:
    print("  BROKEN DIAG lines (use 'dev' variable outside genx320_power_on):")
    for lineno, func, text in problems:
        print(f"    line {lineno:4d}  in {func}():")
        print(f"           {text[:100]}")
        print(f"           Fix: replace 'dev' with &genx320->pcw.dev  (or remove the line)")
    print("")
    print("  These lines will not compile because 'dev' is not defined")
    print("  in those functions — only genx320_power_on takes 'struct device *dev'.")
else:
    print("  No broken DIAG lines detected.")
    print("  DIAG injections look OK — build failure has a different cause.")
PYEOF

    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}━━━━  STEP 3 / 4   Fix the source  ━━━━${N}"
echo ""

FIXED=0

if [ -n "$SRC" ] && [ -f "$SRC" ]; then
    ORIG="${SRC}.orig"

    if [ -f "$ORIG" ]; then
        info "Backup found: $ORIG"
        info "Restoring original genx320.c..."
        cp "$ORIG" "$SRC"
        pass "Restored $SRC from backup."
        FIXED=1
    else
        warn "No .orig backup found."
        info "Re-cloning drivers/ from Prophesee repo (make prepare)..."
        echo ""
        rm -rf drivers
        if make prepare 2>&1; then
            pass "make prepare succeeded — drivers/ re-cloned."
            SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)
            FIXED=1
        else
            fail "make prepare failed — check network/git access."
            echo ""
            echo "  Manual fix:"
            echo "    rm -rf drivers"
            echo "    git clone --branch kernel-6.12 https://github.com/prophesee-ai/linux-sensor-drivers.git drivers"
            echo "    git -C drivers checkout 7165d5e69ebed78dcc63b36e1d0f451c42aa7aaa"
            exit 1
        fi
    fi
else
    info "drivers/genx320.c not found — running make prepare..."
    if make prepare 2>&1; then
        pass "make prepare succeeded."
        SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)
        FIXED=1
    else
        fail "make prepare failed."
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}━━━━  STEP 4 / 4   Rebuild and reinstall  ━━━━${N}"
echo ""

if [ "$FIXED" = "1" ]; then
    info "Building: make psee_sensors"
    echo ""
    if make psee_sensors 2>&1; then
        pass "Build succeeded."
        echo ""
        info "Installing DKMS module..."
        if dkms install psee_sensor_drivers/1.0.1 -k "${KVER}" 2>&1; then
            pass "DKMS install succeeded."
        else
            warn "dkms install reported an error (may already be at latest)."
            dkms status 2>/dev/null | grep psee || true
        fi
        echo ""
        KO=$(find "/lib/modules/${KVER}" -name "genx320-driver.ko*" 2>/dev/null | head -1)
        if [ -n "$KO" ]; then
            pass "Module installed: $KO"
        fi
        echo ""
        pass "Build fixed.  Next: sudo ./scripts/probe_watch.sh"
    else
        echo ""
        fail "Build still failing after source restore."
        echo ""
        info "First compiler error:"
        make psee_sensors 2>&1 | grep -m5 'error:' || true
        echo ""
        echo "  This is no longer a source issue — likely a kernel-headers problem."
        echo "  Check:"
        echo "    ls /lib/modules/\$(uname -r)/build/Makefile"
        echo "    sudo apt-get install --reinstall linux-headers-\$(uname -r)"
        echo "    gcc --version"
    fi
else
    fail "Source not fixed — cannot build."
fi

rm -f "$BUILD_OUT"
echo ""
echo "Log: $LOG"
