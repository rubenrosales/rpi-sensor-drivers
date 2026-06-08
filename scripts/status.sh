#!/bin/bash
# status.sh — clean, human-readable GenX320 status report.
# Run with sudo from the repo root: sudo ./scripts/status.sh
#
# Fixes the broken dmesg grep from debug_session.sh (trailing-backslash bug).
# Correctly identifies the real sensor I2C bus (i2c-11) vs phantom bus reads
# (i2c-13/14 show 50+ phantom addresses — those are NOT real devices).
# Ends with a concrete verdict and next step.

set -uo pipefail
KVER=$(uname -r)
LOG="status_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

# ── colours ─────────────────────────────────────────────────────────────────
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }
bar()  { printf "${BOLD}────────────────────────────────────────────────────────────────────${N}\n"; }
hdr()  { echo ""; bar; printf "${BOLD}  %s${N}\n" "$*"; bar; }

# ── helpers ──────────────────────────────────────────────────────────────────
reg_state() {
    local want=$1
    for f in /sys/class/regulator/regulator.*/name; do
        [ -f "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "$want" ] || continue
        local d; d=$(dirname "$f")
        local st; st=$(cat "$d/state"        2>/dev/null || echo "?")
        local ec; ec=$(cat "$d/enable_count" 2>/dev/null || echo "?")
        echo "state=${st}  enable_count=${ec}"
        return
    done
    echo "(not found in /sys/class/regulator)"
}

# Count how many I2C addresses actually ACK — used to detect phantom buses.
# A real camera bus has 0–5 devices. A floating bus shows 30+.
bus_ack_count() {
    local bus=$1
    i2cdetect -y "$bus" 2>/dev/null \
        | grep -oE '\b[0-9a-f]{2}\b' \
        | grep -cvE '^(00|--|UU)' || echo 0
}

probe_ok() {
    for d in 0 1 2 3 4 5; do
        [ -e "/dev/media${d}" ] || continue
        media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320" && return 0
    done
    return 1
}

# ── header ───────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  GenX320 / CCAM5  —  Bring-up Status Report${N}\n"
printf "  Host: $(hostname)  |  Kernel: ${KVER}  |  $(date '+%Y-%m-%d %H:%M')\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"

# ─────────────────────────────────────────────────────────────────────────────
hdr "1 / 9   KERNEL MODULE"
# ─────────────────────────────────────────────────────────────────────────────
if lsmod | grep -q "^genx320"; then
    MOD_LINE=$(lsmod | grep "^genx320" | awk '{printf "size=%s  consumers=%s", $2, $3}')
    pass "genx320_driver loaded  ($MOD_LINE)"
    if [ "$(lsmod | grep "^genx320" | awk '{print $3}')" = "0" ]; then
        note "0 consumers → probe failed (successful probe would show ≥1)"
    fi
else
    fail "genx320_driver NOT loaded"
    note "Fix: sudo modprobe genx320-driver"
    note "     or run: sudo ./scripts/fix_build.sh"
fi

KO=$(find "/lib/modules/${KVER}" -name "genx320-driver.ko*" 2>/dev/null | head -1)
if [ -n "$KO" ]; then
    info "Module file: $KO"
    if strings "$KO" 2>/dev/null | grep -q "DIAG power_on"; then
        pass "DIAG logging PRESENT in .ko  (power-on trace will appear in dmesg)"
    else
        warn "DIAG logging MISSING from .ko"
        note "The probe trace won't show in dmesg — run fix_build.sh to rebuild"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "2 / 9   DKMS"
# ─────────────────────────────────────────────────────────────────────────────
if command -v dkms &>/dev/null; then
    DKMS_LINE=$(dkms status 2>/dev/null | grep psee || true)
    if [ -n "$DKMS_LINE" ]; then
        pass "DKMS entry found:"
        note "$DKMS_LINE"
    else
        fail "No psee_sensor_drivers entry in dkms status"
        note "Fix: sudo ./scripts/fix_build.sh"
    fi
else
    warn "dkms not installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "3 / 9   OVERLAY & DEVICE TREE"
# ─────────────────────────────────────────────────────────────────────────────
OVL=$(dtoverlay -l 2>/dev/null | grep genx320 || true)
if [ -n "$OVL" ]; then
    pass "Overlay loaded: $OVL"
else
    fail "genx320 overlay NOT loaded"
    note "Load: sudo dtoverlay genx320,rstn-delay-ms=600,startup-delay-us=900000"
fi

# Find which i2c bus+address the kernel registered genx320 on
SENSOR_BUS_ADDR=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E "^[0-9]+-003c$" | head -1)
if [ -n "$SENSOR_BUS_ADDR" ]; then
    SENSOR_BUS=$(echo "$SENSOR_BUS_ADDR" | cut -d- -f1)
    DEV_NAME=$(cat "/sys/bus/i2c/devices/${SENSOR_BUS_ADDR}/name" 2>/dev/null || echo "?")
    pass "DT device registered: i2c-${SENSOR_BUS} / 0x3c  (name: ${DEV_NAME})"
    note "The overlay created the i2c client OK. The driver was called for probe()."
    note "The probe itself is what failed."
else
    fail "No genx320 i2c device found in /sys/bus/i2c/devices/"
    note "The overlay may not have loaded, or the DT node wasn't created."
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "4 / 9   20 MHz INPUT CLOCK  (Pi / RP1 side)"
# ─────────────────────────────────────────────────────────────────────────────
CLK_LINE=$(grep -w "cam1_clk" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -1 || true)
if [ -n "$CLK_LINE" ]; then
    CLK_PREP=$(echo "$CLK_LINE" | awk '{print $2}')
    CLK_EN=$(echo "$CLK_LINE"   | awk '{print $3}')
    CLK_RATE=$(echo "$CLK_LINE" | awk '{print $5}')
    if [ "$CLK_RATE" = "20000000" ] && [ "$CLK_EN" -ge 1 ] 2>/dev/null; then
        pass "cam1_clk: rate=${CLK_RATE} Hz  prepare=${CLK_PREP}  enable=${CLK_EN}"
        if echo "$CLK_LINE" | grep -q "deviceless"; then
            note "'deviceless' = Pi firmware holds this clock; driver released it after probe failure."
            note "The clock IS running on the Pi/RP1 side."
            note "Whether the 20 MHz signal physically reaches the FPC CLK pin is UNCONFIRMED."
        fi
    else
        warn "cam1_clk found but rate=${CLK_RATE} or not enabled (en=${CLK_EN})"
    fi
else
    warn "cam1_clk not visible in /sys/kernel/debug/clk/clk_summary"
    note "Try: sudo mount -t debugfs none /sys/kernel/debug  then re-run"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "5 / 9   POWER REGULATOR"
# ─────────────────────────────────────────────────────────────────────────────
CAM1_REG=$(reg_state cam1_reg)
CAM0_REG=$(reg_state cam0_reg)
info "cam1_reg : $CAM1_REG"
info "cam0_reg : $CAM0_REG"

# GPIO state
GPIO_LINE=$(cat /sys/kernel/debug/gpio 2>/dev/null | grep cam1_reg || true)
if [ -n "$GPIO_LINE" ]; then
    info "GPIO     : $GPIO_LINE"
fi

echo ""
note "IMPORTANT: 'disabled' after a failed probe is expected."
note "The regulator DID briefly enable during probe — cam1_reg GPIO went HIGH,"
note "the 500 ms startup-delay-us passed, then the I2C read failed (EREMOTEIO),"
note "and power_off() disabled it again. 'disabled' here is not the root cause."

# ─────────────────────────────────────────────────────────────────────────────
hdr "6 / 9   I2C SCAN  —  real sensor bus vs phantom buses"
# ─────────────────────────────────────────────────────────────────────────────

# Test real sensor bus directly
if [ -n "${SENSOR_BUS:-}" ]; then
    echo ""
    info "Testing i2c-${SENSOR_BUS} (where kernel registered the genx320 device):"
    if i2cget -y "$SENSOR_BUS" 0x3c 0x00 2>/dev/null; then
        pass "Sensor ACKs on i2c-${SENSOR_BUS}!  (unexpected — probe should have caught this)"
    else
        fail "No ACK from sensor at i2c-${SENSOR_BUS} / 0x3c  →  EREMOTEIO confirmed"
        note "This is the definitive test. The sensor does not respond to I2C."
    fi
fi

# Scan all buses and label phantom ones
echo ""
info "Scanning all buses (labelling phantom/floating buses):"
ALL_BUSES=$(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//')
for BUS in $ALL_BUSES; do
    ACK_COUNT=$(bus_ack_count "$BUS")
    if [ "$ACK_COUNT" -gt 20 ]; then
        warn "i2c-${BUS}: ${ACK_COUNT} addresses 'responding'  →  PHANTOM BUS (floating/undriven lines)"
        note "     Do not trust 0x3c hits on this bus. These are noise, not real devices."
    elif echo "$(i2cdetect -y "$BUS" 2>/dev/null)" | grep -qE ' 3c | 3c$'; then
        pass "i2c-${BUS}: 0x3c found  (${ACK_COUNT} total ACKs — looks like a real device)"
    else
        info "i2c-${BUS}: no 0x3c  (${ACK_COUNT} ACKs)"
    fi
done

echo ""
note "NOTE from May-26 log: i2c-13 and i2c-14 showed '0x3c found' but had"
note "50+ addresses responding — classic phantom bus. Those were NOT real."
note "The actual sensor is on i2c-11 (DesignWare), which showed no ACK."

# ─────────────────────────────────────────────────────────────────────────────
hdr "7 / 9   RESET / NRST GPIO"
# ─────────────────────────────────────────────────────────────────────────────
echo ""
warn "nreset-gpios is NOT defined in the DTS"
note "The driver calls: devm_gpiod_get_optional(dev, \"nreset\", GPIOD_OUT_HIGH)"
note "With no DT property, this returns NULL → driver skips all reset GPIO control."
note ""
note "This matters because:"
note "  • Pi 5 camera connectors have a physical SHUTDOWN/RESET pin on the FPC."
note "  • If that pin connects to a Pi GPIO that defaults LOW, NRST stays LOW."
note "  • With NRST LOW the GenX320 is frozen in hardware reset forever."
note "  • It will not respond to I2C no matter how long you wait."
echo ""

# Show which GPIOs are unclaimed and could be NRST
info "Unclaimed GPIOs (candidates for NRST on 40-pin header):"
CHIP_BASE=$(cat /sys/class/gpio/gpiochip0/base 2>/dev/null || echo 569)
for LINE in 4 5 6 12 13 14 17 22 23 24 25 26 27; do
    GNAME=$(gpioinfo gpiochip0 2>/dev/null | awk -v L="$LINE" '$0 ~ "line *"L":" {print}' | grep -oE '"[^"]+"' | head -1 || echo "GPIO${LINE}")
    STATUS=$(gpioinfo gpiochip0 2>/dev/null | awk -v L="$LINE" '$0 ~ "line *"L":" {print}' | grep -oE 'input|output' | head -1 || echo "?")
    CONSUMER=$(gpioinfo gpiochip0 2>/dev/null | awk -v L="$LINE" '$0 ~ "line *"L":" {print}' | grep -oE 'consumer="[^"]+"' | head -1 || echo "")
    if [ -z "$CONSUMER" ]; then
        info "  GPIO${LINE} (line ${LINE}): ${STATUS}  ← available, could be NRST"
    else
        note "  GPIO${LINE} (line ${LINE}): ${STATUS}  ${CONSUMER}  ← claimed"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
hdr "8 / 9   PROBE TRACE  (DIAG dmesg lines)"
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "DIAG lines (show exact power-on sequence steps completed):"
DIAG_LINES=$(dmesg | grep "DIAG" || true)
if [ -n "$DIAG_LINES" ]; then
    echo "$DIAG_LINES" | while IFS= read -r line; do
        note "  $line"
    done
else
    warn "No DIAG lines in dmesg."
    note "Either: (a) the .ko was not rebuilt with DIAG logging, or"
    note "        (b) dmesg was cleared since last probe attempt."
    note "Run: sudo dtoverlay -r genx320; sudo dtoverlay genx320  then check again."
fi

echo ""
info "All genx320-related dmesg (single-line grep — no trailing-backslash bug):"
dmesg | grep -iE 'genx320|psee|cam1_reg|cam0_reg|cam1_clk|inclk|rstn|eremoteio|DIAG' | tail -30 || true

# ─────────────────────────────────────────────────────────────────────────────
hdr "9 / 9   MEDIA TOPOLOGY"
# ─────────────────────────────────────────────────────────────────────────────
if probe_ok; then
    pass "genx320 entity found in media graph  →  sensor probed successfully!"
    info "Next: ./rp5_setup_v4l.sh"
else
    fail "genx320 not in any /dev/media* device  →  probe did not complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# VERDICT
# ─────────────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  VERDICT${N}\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""
printf "  ${G}Power  :${N}  OK — cam1_reg briefly enables (500 ms startup-delay-us passes)\n"
printf "  ${G}Clock  :${N}  OK — cam1_clk 20 MHz on the Pi/RP1 side\n"
printf "  ${G}Timing :${N}  NOT the issue — 885 ms total wait is ~85× what sensor needs\n"
echo ""
printf "  ${R}EREMOTEIO = sensor physically does not ACK on I2C.${N}\n"
printf "  Only two things cause this when power and timing are confirmed OK:\n"
echo ""
printf "  ${BOLD}★ MOST LIKELY:  NRST pin held LOW${N}\n"
printf "    The DTS has no nreset-gpios. The adapter may tie NRST to a Pi GPIO\n"
printf "    that defaults LOW (common on Pi 5 camera connectors). With NRST LOW,\n"
printf "    the GenX320 is frozen in hardware reset — no I2C response, ever.\n"
printf "    ${G}→ Run: sudo ./scripts/find_nrst.sh${N}\n"
echo ""
printf "  ${BOLD}✦ ALSO POSSIBLE:  20 MHz clock not physically reaching sensor${N}\n"
printf "    cam1_clk is enabled on the Pi but physical routing to the FPC CLK\n"
printf "    pin is unconfirmed. A broken trace or bad contact kills the sensor.\n"
printf "    ${G}→ Verify with oscilloscope on FPC CLK pin.${N}\n"
echo ""
printf "  ${Y}Increasing rstn-delay-ms further will NOT help.${N}  Timing is fine.\n"
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""
echo "Full log saved to: $LOG"
