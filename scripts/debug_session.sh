#!/bin/bash
# Full debug session for GenX320 / CCAM5 on Raspberry Pi 5.
# Run with sudo: sudo ./scripts/debug_session.sh
#
# Covers:
#   1.  System info
#   2.  Kernel module
#   3.  DKMS status
#   4.  Device-tree overlay
#   5.  Full dmesg dump (filtered)
#   6.  Power-rail analysis
#   7.  Clock state
#   8.  Regulator state
#   9.  I2C bus scan
#   10. GPIO state
#   11. Media topology
#   12. Driver source inspection
#   13. Auto-inject DIAG logging into drivers/genx320.c and rebuild

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
head_()  { echo -e "\n${CYAN}======================================================================${NC}"; \
           echo -e "${CYAN} $*${NC}"; \
           echo -e "${CYAN}======================================================================${NC}"; }
sep()   { echo -e "\n----------------------------------------------------------------------\n"; }

LOG_FILE="genx320_debug_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to $LOG_FILE"

# ---------------------------------------------------------------------------
head_ "1. System information"
# ---------------------------------------------------------------------------
echo "Date        : $(date)"
echo "Kernel      : $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Hostname    : $(hostname)"
if [ -f /proc/device-tree/model ]; then
    echo "Pi model    : $(tr -d '\0' < /proc/device-tree/model)"
fi
if command -v vcgencmd &>/dev/null; then
    echo "Firmware    : $(vcgencmd version 2>/dev/null | head -1 || true)"
fi

# ---------------------------------------------------------------------------
head_ "2. Kernel module"
# ---------------------------------------------------------------------------
if lsmod | grep -qE "^genx320"; then
    ok "genx320 module is loaded."
    lsmod | grep genx320
else
    fail "genx320 module NOT loaded."
    echo "   -> sudo modprobe genx320-driver"
fi

sep
info "Module info (if available):"
modinfo genx320-driver 2>/dev/null || modinfo genx320 2>/dev/null || warn "modinfo not available for genx320."

# ---------------------------------------------------------------------------
head_ "3. DKMS status"
# ---------------------------------------------------------------------------
if command -v dkms &>/dev/null; then
    dkms status 2>/dev/null | grep -i "psee\|genx320" || warn "No psee_sensor_drivers DKMS entry found."
else
    warn "dkms not installed."
fi

# ---------------------------------------------------------------------------
head_ "4. Device-tree overlay"
# ---------------------------------------------------------------------------
info "Currently loaded overlays:"
dtoverlay -l 2>/dev/null || warn "dtoverlay -l failed."

sep
info "Searching /proc/device-tree for genx320 node..."
DT_FOUND=0
if find /proc/device-tree -name "compatible" 2>/dev/null \
        | xargs grep -l "psee,genx320" 2>/dev/null | grep -q .; then
    DT_FOUND=1
    ok "genx320 DT node found."
    find /proc/device-tree -name "compatible" 2>/dev/null \
        | xargs grep -l "psee,genx320" 2>/dev/null || true
else
    fail "genx320 DT node NOT found in /proc/device-tree."
    echo "   -> sudo dtoverlay genx320      (cam1)"
    echo "   -> sudo dtoverlay genx320,cam0 (cam0)"
fi

sep
info "I2C devices registered with the kernel:"
ls /sys/bus/i2c/devices/ 2>/dev/null || true
for d in /sys/bus/i2c/devices/*/name; do
    [ -f "$d" ] && echo "  $(dirname $d | xargs basename): $(cat $d)"
done

# ---------------------------------------------------------------------------
head_ "5. Full dmesg dump (genx320 / power / clock / I2C)"
# ---------------------------------------------------------------------------
info "All matching dmesg lines (most recent 80):"
dmesg | grep -iE \
    'genx320|psee|cam[01]_reg|cam[01]_clk|rp1.cfe|regulator.*cam|cam.*regul|\
inclk|rstn|reset.*cam|cam.*reset|i2c.*3c|3c.*i2c|eremoteio|\
power.on|power.off|failed.*sensor|sensor.*failed|boot.*sensor|sensor.*boot|\
gpio.*cam|cam.*gpio|vc4|csi[01]|mipicsi' \
    | tail -80 || true

# ---------------------------------------------------------------------------
head_ "6. Power-rail analysis"
# ---------------------------------------------------------------------------
EREMOTEIO=0; REG_SEEN=0; PWR_FAIL=0; BOOT_FAIL=0

dmesg | grep -q "register read ret -121"        && EREMOTEIO=1
dmesg | grep -qiE 'cam[01]_reg.*enabl|enabl.*cam[01]_reg|cam[01]_reg.*on' && REG_SEEN=1
dmesg | grep -qi  "Failed to power"              && PWR_FAIL=1
dmesg | grep -qi  "Failed to boot"               && BOOT_FAIL=1

echo "  EREMOTEIO (-121) seen : $EREMOTEIO"
echo "  cam_reg enable seen   : $REG_SEEN"
echo "  'Failed to power' seen: $PWR_FAIL"
echo "  'Failed to boot' seen : $BOOT_FAIL"
echo ""

if [ "$PWR_FAIL" = "1" ]; then
    fail "'Failed to power-on sensor' — one of the regulators, clock, or reset GPIO failed to initialise."
    echo "   Likely causes:"
    echo "   (A) cam_reg (3.3 V supply) not enabling — FPC unseated or wrong cam slot."
    echo "   (B) 20 MHz inclk not programmed — RP1 GPCLK not running."
    echo "   (C) Reset GPIO conflict — another driver or overlay owns the pin."
    echo "   (D) Regulator driver not loaded — check 'regulator' in dmesg."
fi
if [ "$EREMOTEIO" = "1" ]; then
    fail "-EREMOTEIO: sensor did not ACK on I2C. It is powered but not responding."
    echo "   Likely causes:"
    echo "   (A) 20 MHz clock not reaching sensor."
    echo "   (B) NRST stuck LOW."
    echo "   (C) rstn-delay-ms too short — try 600 ms."
fi

# ---------------------------------------------------------------------------
head_ "7. Clock state"
# ---------------------------------------------------------------------------
info "Checking debugfs clock summary for cam/gpclk clocks..."
if mountpoint -q /sys/kernel/debug 2>/dev/null; then
    grep -iE 'cam|gpclk|inclk|clk_[01]' /sys/kernel/debug/clk/clk_summary 2>/dev/null \
        || warn "No cam/gpclk entries in clk_summary."
    sep
    info "GPCLK entries specifically:"
    grep -i gpclk /sys/kernel/debug/clk/clk_summary 2>/dev/null || warn "No gpclk entries."
else
    warn "debugfs not mounted. Mount with: sudo mount -t debugfs none /sys/kernel/debug"
fi

sep
info "Checking /sys/kernel/debug/regulator for cam regulators..."
if [ -d /sys/kernel/debug/regulator ]; then
    ls /sys/kernel/debug/regulator/ | grep -i cam || warn "No cam regulators visible in debugfs."
    for r in /sys/kernel/debug/regulator/*cam*; do
        [ -d "$r" ] || continue
        echo "  $(basename $r):"
        cat "$r/enable_count" 2>/dev/null && echo "    enable_count: $(cat $r/enable_count)"
        cat "$r/voltage" 2>/dev/null      && echo "    voltage: $(cat $r/voltage)"
    done
else
    warn "/sys/kernel/debug/regulator not available."
fi

# ---------------------------------------------------------------------------
head_ "8. Regulator state (/sys/class/regulator)"
# ---------------------------------------------------------------------------
info "All regulators:"
for r in /sys/class/regulator/regulator.*/name; do
    [ -f "$r" ] || continue
    NAME=$(cat "$r")
    DIR=$(dirname "$r")
    STATE=$(cat "$DIR/state" 2>/dev/null || echo "?")
    echo "  $NAME : $STATE"
done | grep -iE 'cam|3v3|vdd|supply|dummy' || echo "  (no cam/vdd regulators found in /sys/class/regulator)"

# ---------------------------------------------------------------------------
head_ "9. I2C bus scan"
# ---------------------------------------------------------------------------
info "All I2C buses:"
i2cdetect -l 2>/dev/null || fail "i2c-tools not installed: sudo apt install i2c-tools"

sep
info "Scanning all buses for device at 0x3c..."
ALL_BUSES=$(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//')
FOUND_3C=0
for BUS in $ALL_BUSES; do
    SCAN=$(i2cdetect -y "$BUS" 2>/dev/null) || continue
    if echo "$SCAN" | grep -qE ' 3c | 3c$'; then
        ok "Device at 0x3c found on i2c-${BUS}!"
        FOUND_3C=1
        echo "$SCAN"
    fi
done
if [ "$FOUND_3C" = "0" ]; then
    fail "No device at 0x3c on any bus."
    info "Camera buses (DesignWare / CSI):"
    i2cdetect -l 2>/dev/null | grep -iE 'DesignWare|csi|cam' || true
    CAM_BUSES=$(i2cdetect -l 2>/dev/null | grep -iE 'DesignWare|csi|cam' | awk '{print $1}' | sed 's/i2c-//')
    for BUS in $CAM_BUSES; do
        echo "  --- i2c-${BUS} full scan ---"
        i2cdetect -y "$BUS" 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
head_ "10. GPIO state"
# ---------------------------------------------------------------------------
info "GPIO lines referencing cam/reset/csi:"
if [ -f /sys/kernel/debug/gpio ]; then
    grep -iE 'cam|reset|csi|genx320|rstn' /sys/kernel/debug/gpio 2>/dev/null \
        || warn "No cam/reset GPIO lines found in debugfs."
else
    warn "/sys/kernel/debug/gpio not available."
fi

sep
info "All GPIO lines (gpioinfo):"
command -v gpioinfo &>/dev/null && gpioinfo 2>/dev/null | head -80 || warn "gpioinfo not installed: sudo apt install gpiod"

# ---------------------------------------------------------------------------
head_ "11. Media topology"
# ---------------------------------------------------------------------------
ENTITY_FOUND=0
for d in {0..9}; do
    [ -e "/dev/media${d}" ] || continue
    info "Checking /dev/media${d}..."
    if media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320"; then
        ok "genx320 entity found in /dev/media${d}!"
        ENTITY_FOUND=1
        media-ctl -p -d "$d" 2>/dev/null
        break
    fi
done
[ "$ENTITY_FOUND" = "0" ] && fail "genx320 not in any /dev/media* device."

# ---------------------------------------------------------------------------
head_ "12. Driver source inspection"
# ---------------------------------------------------------------------------
SRC="drivers/genx320.c"
if [ ! -f "$SRC" ]; then
    # try subdirectory layout
    SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    fail "drivers/genx320.c not found. Run 'make prepare' first."
else
    ok "Found source: $SRC"
    sep
    info "Power/regulator/clock/reset/GPIO lines in source:"
    grep -n "power\|regul\|clk\|reset\|gpio\|delay\|msleep\|usleep\|Failed\|err\|boot" "$SRC" \
        | grep -iv "copyright\|spdx\|author" | head -60

    sep
    info "Functions defined in source:"
    grep -n "^static\|^int\|^void" "$SRC" | head -40
fi

# ---------------------------------------------------------------------------
head_ "13. Auto-inject DIAG logging and rebuild"
# ---------------------------------------------------------------------------
SRC="drivers/genx320.c"
if [ ! -f "$SRC" ]; then
    SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    fail "Cannot inject logging — source not found."
else
    if grep -q "DIAG power_on" "$SRC"; then
        ok "DIAG logging already present in $SRC — skipping injection."
    else
        info "Injecting DIAG logging into $SRC ..."

        # Back up original
        cp "$SRC" "${SRC}.orig"

        # Find the function containing power-on / regulator logic.
        # Strategy: find lines that call regulator_enable, clk_prepare_enable,
        # gpiod_set_value, msleep/usleep after a reset, and insert dev_info after each.

        python3 - "$SRC" <<'PYEOF'
import sys, re, shutil

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.rstrip()

    # After: regulator_enable(...)  — next non-blank/brace line
    if re.search(r'regulator_enable\s*\(', stripped) and 'err' not in stripped.lower():
        out.append(line)
        # peek ahead for the closing of the if-block or next statement
        out.append('\tdev_info(dev, "DIAG power_on: regulator enabled (%s)\\n", __func__);\n')
        i += 1
        continue

    # After: clk_prepare_enable(...)
    if re.search(r'clk_prepare_enable\s*\(', stripped):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: inclk enabled\\n");\n')
        i += 1
        continue

    # After: gpiod_set_value / gpiod_set_value_cansleep (reset deassert)
    if re.search(r'gpiod_set_value', stripped):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: reset GPIO set\\n");\n')
        i += 1
        continue

    # After: msleep / usleep_range following a reset or delay comment
    if re.search(r'\bmsleep\b|\busleep_range\b|\budelay\b', stripped):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: post-delay done, beginning I2C probe\\n");\n')
        i += 1
        continue

    # Before the register read that can return -EREMOTEIO
    # (line containing read_reg / regmap_read immediately followed by error check for -121)
    if re.search(r'(regmap_read|read_reg|i2c_smbus_read)', stripped):
        out.append('\tdev_info(dev, "DIAG identify: attempting chip-ID register read\\n");\n')
        out.append(line)
        i += 1
        continue

    out.append(line)
    i += 1

with open(path, 'w') as f:
    f.writelines(out)

print(f"  Injected DIAG lines into {path}")
PYEOF

        if grep -q "DIAG" "$SRC"; then
            ok "DIAG lines injected successfully."
        else
            warn "Python injection produced no changes — source structure may differ."
            warn "Inspect $SRC manually for power_on / regulator_enable / clk_prepare_enable."
        fi

        sep
        info "Lines injected (context):"
        grep -n "DIAG" "$SRC" || true

        sep
        info "Rebuilding driver..."
        if [ ! -d drivers ]; then
            warn "drivers/ directory not found. Running 'make prepare' first..."
            make prepare
        fi
        make psee_sensors

        sep
        ok "Build done. Now run:"
        echo ""
        echo "   sudo dkms install psee_sensor_drivers/1.0.1 -k \$(uname -r)"
        echo "   sudo dtoverlay -r genx320 2>/dev/null; sudo dtoverlay genx320"
        echo "   dmesg | grep DIAG"
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
head_ "Session complete"
# ---------------------------------------------------------------------------
echo "Full log saved to: $LOG_FILE"
echo ""
echo "Share $LOG_FILE for remote diagnosis."
