#!/bin/bash
# check_power.sh — hold cam1_reg ON and verify power physically reaches the sensor.
# Run with sudo from repo root: sudo ./scripts/check_power.sh
#
# All previous debug attempts (GPIO sweeps, probe watches) only confirmed that
# the cam1_reg GPIO *pin* goes HIGH inside the kernel.  None of them confirmed
# that 3.3 V physically reaches the GenX320 on the other end of the FPC.
# This script holds power on persistently so you can measure with a multimeter.

set -uo pipefail

R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }

LOG="check_power_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  GenX320 Power Verification — hold power on and measure${N}\n"
printf "  $(date '+%Y-%m-%d %H:%M')  |  Kernel: $(uname -r)\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"

# ── step 1: load overlay with always-on ──────────────────────────────────────
echo ""
printf "${BOLD}━━━━  STEP 1 / 3   Load overlay with always-on regulator  ━━━━${N}\n"
echo ""

dtoverlay -r genx320 2>/dev/null || true
sleep 1

info "Loading: dtoverlay genx320,always-on,rstn-delay-ms=600,startup-delay-us=900000"
dtoverlay genx320,always-on,rstn-delay-ms=600,startup-delay-us=900000

# Wait for startup-delay-us + probe to finish
sleep 6

# Check cam1_reg state in sysfs
CAM1_STATE="unknown"
for f in /sys/class/regulator/regulator.*/name; do
    [ "$(cat "$f" 2>/dev/null)" = "cam1_reg" ] || continue
    D=$(dirname "$f")
    CAM1_STATE=$(cat "$D/state"        2>/dev/null || echo "?")
    CAM1_COUNT=$(cat "$D/enable_count" 2>/dev/null || echo "?")
    CAM1_VOLT=$(cat  "$D/voltage"      2>/dev/null || echo "?")
done

echo ""
if [ "$CAM1_STATE" = "enabled" ]; then
    pass "cam1_reg: ENABLED  (enable_count=${CAM1_COUNT}  voltage=${CAM1_VOLT} μV)"
    note "GPIO gpiochip0:46 (CD1_IO0_MICCLK) is driving HIGH."
    note "The Pi 5 is asserting the 3V3 power enable signal on the CAM1 connector."
else
    fail "cam1_reg: ${CAM1_STATE}  (expected 'enabled' with always-on)"
    note "The always-on overlay fragment may not have activated correctly."
    note "Check: dtoverlay -l"
fi

# GPIO raw state
GPIO_RAW=$(cat /sys/kernel/debug/gpio 2>/dev/null | grep cam1_reg || true)
[ -n "$GPIO_RAW" ] && info "GPIO: $GPIO_RAW"

# ── step 2: measure ──────────────────────────────────────────────────────────
echo ""
printf "${BOLD}━━━━  STEP 2 / 3   MEASURE WITH MULTIMETER NOW  ━━━━${N}\n"
echo ""

printf "  ${BOLD}cam1_reg is held ON.  Do these measurements now:${N}\n\n"

printf "  ${BOLD}Measurement A — confirm Pi is outputting 3.3 V${N}\n"
printf "  Probe: any GND pin on the Pi 40-pin header  (e.g. pin 6)\n"
printf "         vs. the cam1_reg GPIO on the Pi FPC connector:\n"
printf "             Pi 5 CAM1 22-pin connector, pin 15 (3V3 rail)\n"
printf "  Expected: ~3.3 V\n"
printf "  If 0 V: the Pi 5 load switch for CAM1_3V3 is not enabling.\n\n"

printf "  ${BOLD}Measurement B — confirm 3.3 V reaches the CCAM5 adapter${N}\n"
printf "  Probe: GND on adapter board  vs.  3V3 pad on adapter board\n"
printf "  Expected: ~3.3 V\n"
printf "  If 0 V: FPC power pin (pin 15) is not making contact.\n\n"

printf "  ${BOLD}Measurement C — confirm MCLK is toggling${N}\n"
printf "  Probe: GND  vs.  Pi CAM1 connector pin 11 (CAM1_MCLK)\n"
printf "  Expected: ~0.9 V DC average on a multimeter (= 1.8 V p-p, 50%% duty)\n"
printf "  If 0 V: MCLK is not reaching the connector.\n\n"

printf "  ${Y}Power is held ON.  Press ENTER when you have your measurements.${N}\n"
read -r _

# ── step 3: i2c scan while power is confirmed on ─────────────────────────────
echo ""
printf "${BOLD}━━━━  STEP 3 / 3   I2C scan with power held on  ━━━━${N}\n"
echo ""

# Find the sensor bus
SENSOR_BUS_ADDR=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E "^[0-9]+-003c$" | head -1)
if [ -n "$SENSOR_BUS_ADDR" ]; then
    SENSOR_BUS=$(echo "$SENSOR_BUS_ADDR" | cut -d- -f1)
    info "Sensor bus: i2c-${SENSOR_BUS} / 0x3c"
    echo ""

    info "Direct probe: i2cget -y ${SENSOR_BUS} 0x3c 0x00"
    if i2cget -y "$SENSOR_BUS" 0x3c 0x00 2>/dev/null; then
        pass "Sensor ACKs on i2c-${SENSOR_BUS}!  Power is reaching it."
    else
        fail "No ACK on i2c-${SENSOR_BUS} / 0x3c  (EREMOTEIO)"
        note "Power (cam1_reg) is confirmed ON by sysfs."
        note "If your multimeter showed 3.3 V at the adapter: power is physically reaching it."
        note "If 0 V at the adapter: FPC connection or Pi load switch is the problem."
    fi

    echo ""
    info "Full scan of i2c-${SENSOR_BUS} (real bus — not the phantom CSI buses):"
    i2cdetect -y "$SENSOR_BUS" 2>/dev/null || true
    ACK_COUNT=$(i2cdetect -y "$SENSOR_BUS" 2>/dev/null \
        | grep -oE '\b[0-9a-f]{2}\b' | grep -cvE '^(00|--|UU)' || echo 0)
    note "${ACK_COUNT} address(es) responding on i2c-${SENSOR_BUS}"
    if [ "$ACK_COUNT" -gt 20 ]; then
        warn "More than 20 addresses responding — this is a phantom/floating bus read."
        note "Ignore these results and trust the i2cget result above."
    fi
else
    warn "No genx320 device found in /sys/bus/i2c/devices/"
    note "The DT overlay may not have created the i2c client."
    echo ""
    info "Scanning all buses for any device at 0x3c:"
    for BUS in $(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//'); do
        if i2cget -y "$BUS" 0x3c 0x00 2>/dev/null; then
            pass "0x3c ACKs on i2c-${BUS}!"
        fi
    done
fi

# Cleanup
echo ""
info "Removing overlay..."
dtoverlay -r genx320 2>/dev/null || true

# Summary
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  What your results mean${N}\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""
printf "  Multimeter shows 3.3 V at adapter  +  i2cget ACKs   → sensor alive, NRST issue\n"
printf "  Multimeter shows 3.3 V at adapter  +  i2cget no ACK → MCLK or NRST issue\n"
printf "  Multimeter shows   0 V at adapter  +  i2cget no ACK → FPC power pin not seated\n"
printf "  Multimeter shows   0 V at Pi pin   +  i2cget no ACK → Pi load switch fault\n"
echo ""
printf "  ${BOLD}Share your multimeter readings and the log and we will know exactly what to fix.${N}\n"
echo ""
echo "Log: $LOG"
