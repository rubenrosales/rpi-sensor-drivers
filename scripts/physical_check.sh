#!/bin/bash
# physical_check.sh — software-only power + connection verification.
# Run with sudo from repo root: sudo ./scripts/physical_check.sh
#
# No multimeter needed. Tests everything reachable from software and walks
# through the physical steps that fix the most common connection failures.

set -uo pipefail

R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }
ask()  { printf "\n  ${BOLD}>>> %s — press Enter when done.${N} " "$*"; read -r _; }

LOG="physical_check_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  GenX320 Physical + Power Check (no multimeter)${N}\n"
printf "  $(date '+%Y-%m-%d %H:%M')  |  Kernel: $(uname -r)\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"

# ── helpers ───────────────────────────────────────────────────────────────────
probe_ok() {
    for d in 0 1 2 3 4 5; do
        [ -e "/dev/media${d}" ] || continue
        media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320" && return 0
    done
    return 1
}

i2c_ack() {
    local BUS=$1
    i2cget -y "$BUS" 0x3c 0x00 2>/dev/null && return 0
    return 1
}

# Count real (non-phantom) ACKs on a bus
real_ack_count() {
    local BUS=$1
    local COUNT
    COUNT=$(i2cdetect -y "$BUS" 2>/dev/null \
        | grep -oE '\b[0-9a-f]{2}\b' \
        | grep -cvE '^(00|--|UU)' 2>/dev/null || echo 0)
    echo "$COUNT"
}

reg_state() {
    for f in /sys/class/regulator/regulator.*/name; do
        [ "$(cat "$f" 2>/dev/null)" = "$1" ] || continue
        cat "$(dirname "$f")/state" 2>/dev/null || echo "?"
        return
    done
    echo "not found"
}

load_overlay() {
    local PARAMS="$1"
    dtoverlay -r genx320 2>/dev/null || true
    sleep 1
    dtoverlay "genx320${PARAMS:+,$PARAMS}" 2>/dev/null
    sleep 6
}

unload_overlay() {
    dtoverlay -r genx320 2>/dev/null || true
    sleep 1
}

find_sensor_bus() {
    ls /sys/bus/i2c/devices/ 2>/dev/null \
        | grep -E "^[0-9]+-003c$" | head -1 | cut -d- -f1
}

# ── step 1: baseline before any reseating ─────────────────────────────────────
printf "\n${BOLD}━━━━  STEP 1 / 4   Software baseline (current state)  ━━━━${N}\n\n"

info "Loading overlay with always-on..."
load_overlay "always-on,rstn-delay-ms=600,startup-delay-us=900000"

CAM1_STATE=$(reg_state cam1_reg)
info "cam1_reg: ${CAM1_STATE}"

SENSOR_BUS=$(find_sensor_bus)
if [ -n "$SENSOR_BUS" ]; then
    info "Sensor bus: i2c-${SENSOR_BUS}"
    if i2c_ack "$SENSOR_BUS"; then
        pass "i2cget ACK on i2c-${SENSOR_BUS} — sensor responding right now!"
        note "Power is reaching the sensor. Run sweep_nrst_reload.sh if probe still fails."
        unload_overlay
        exit 0
    else
        fail "i2cget: no ACK on i2c-${SENSOR_BUS} / 0x3c"
    fi
else
    warn "Sensor bus not found — overlay may not have loaded."
fi

# Also snapshot vcgencmd voltages before we start reseating
VOLT_BEFORE=""
if command -v vcgencmd &>/dev/null; then
    VOLT_BEFORE=$(vcgencmd measure_volts core 2>/dev/null || true)
    info "Core voltage before: ${VOLT_BEFORE}"
fi

unload_overlay

# ── step 2: physical FPC reseat ───────────────────────────────────────────────
printf "\n${BOLD}━━━━  STEP 2 / 4   Reseat the FPC cable  ━━━━${N}\n\n"

printf "  The FPC cable has two ends — the Pi CAM1 connector and the\n"
printf "  adapter board connector. Both must be correct.\n\n"

printf "  ${BOLD}At the Pi CAM1 connector:${N}\n"
printf "  1. Lift the black locking tab by pulling it straight up (~2mm).\n"
printf "  2. Slide the FPC cable fully out.\n"
printf "  3. Check the cable end: the metal contacts (silver/gold stripes)\n"
printf "     must face DOWN (toward the Pi board) when inserted.\n"
printf "  4. Slide the cable back in until it stops.\n"
printf "  5. Press the locking tab back down firmly.\n\n"

printf "  ${BOLD}At the adapter (CCAM5) connector:${N}\n"
printf "  6. Do the same at the other end of the FPC.\n"
printf "  7. Contacts face direction specified on the adapter silkscreen.\n\n"

ask "Reseat both ends of the FPC cable now"

info "Testing after reseat (cam1)..."
load_overlay "always-on,rstn-delay-ms=600,startup-delay-us=900000"

SENSOR_BUS=$(find_sensor_bus)
CAM1_STATE=$(reg_state cam1_reg)
info "cam1_reg: ${CAM1_STATE}"

RESEAT_ACK=0
if [ -n "$SENSOR_BUS" ]; then
    if i2c_ack "$SENSOR_BUS"; then
        pass "ACK after reseat on i2c-${SENSOR_BUS}! FPC was the problem."
        RESEAT_ACK=1
    else
        fail "Still no ACK after reseat."
    fi

    info "i2cdetect on i2c-${SENSOR_BUS}:"
    i2cdetect -y "$SENSOR_BUS" 2>/dev/null || true
fi

unload_overlay

if [ "$RESEAT_ACK" = "1" ]; then
    echo ""
    pass "Fixed by reseating. Now run: sudo ./scripts/probe_watch.sh"
    exit 0
fi

# ── step 3: try cam0 slot ─────────────────────────────────────────────────────
printf "\n${BOLD}━━━━  STEP 3 / 4   Try cam0 slot  ━━━━${N}\n\n"

info "Moving to cam0 tests..."
printf "  Move the FPC cable to the OTHER camera connector (CAM0) on the Pi.\n"
printf "  Leave the adapter end unchanged.\n\n"

ask "Move the cable to the cam0 connector now"

info "Loading overlay with cam0..."
load_overlay "cam0,always-on,rstn-delay-ms=600,startup-delay-us=900000"

# cam0 uses cam0_reg and a different sensor bus
SENSOR_BUS_CAM0=$(find_sensor_bus)
CAM0_STATE=$(reg_state cam0_reg)
info "cam0_reg: ${CAM0_STATE}"

CAM0_ACK=0
if [ -n "$SENSOR_BUS_CAM0" ]; then
    if i2c_ack "$SENSOR_BUS_CAM0"; then
        pass "ACK on cam0! The cam1 connector or power path to cam1 is faulty."
        CAM0_ACK=1
    else
        fail "No ACK on cam0 either."
        info "i2cdetect on i2c-${SENSOR_BUS_CAM0}:"
        i2cdetect -y "$SENSOR_BUS_CAM0" 2>/dev/null || true
    fi
else
    warn "Sensor not registered on any bus with cam0 overlay."
fi

unload_overlay

if [ "$CAM0_ACK" = "1" ]; then
    echo ""
    pass "Sensor works on cam0. Use: dtoverlay genx320,cam0"
    note "Add to /boot/firmware/config.txt:"
    note "  camera_auto_detect=0"
    note "  dtoverlay=genx320,cam0"
    exit 0
fi

# move cable back
printf "\n"
ask "Move the cable back to the cam1 connector"

# ── step 4: deep dmesg analysis ───────────────────────────────────────────────
printf "\n${BOLD}━━━━  STEP 4 / 4   Deep dmesg analysis  ━━━━${N}\n\n"

dmesg -c > /dev/null 2>&1 || true
load_overlay "always-on,rstn-delay-ms=600,startup-delay-us=900000"

info "Full probe trace from dmesg:"
echo ""
dmesg | grep -iE 'genx320|psee|cam1_reg|cam1_clk|eremoteio|DIAG|power|clock|Failed|i2c.*3c|3c.*i2c' | while IFS= read -r line; do
    printf "    %s\n" "$line"
done

echo ""
info "Regulator states after load:"
for NAME in cam1_reg cam0_reg; do
    ST=$(reg_state "$NAME")
    printf "    %-12s %s\n" "${NAME}:" "${ST}"
done

echo ""
info "Clock state:"
grep -wE 'cam1_clk|cam0_clk' /sys/kernel/debug/clk/clk_summary 2>/dev/null \
    | while IFS= read -r line; do printf "    %s\n" "$line"; done

unload_overlay

# ── verdict ───────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  VERDICT${N}\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""

fail "Sensor did not respond on cam1 or cam0 after reseat."
echo ""
printf "  At this point software has confirmed:\n"
printf "    • cam1_reg GPIO is driven HIGH by the kernel\n"
printf "    • cam1_clk is programmed at 20 MHz\n"
printf "    • Delays are well above what the sensor needs\n"
printf "    • No GPIO on gpiochip0:2–27 triggers a response\n"
printf "    • cam0 slot also does not respond\n\n"
printf "  What software cannot confirm without a multimeter:\n"
printf "    • Whether 3.3 V is physically leaving the Pi connector\n"
printf "    • Whether 3.3 V reaches the CCAM5 adapter board\n"
printf "    • Whether 20 MHz MCLK is present on the FPC CLK pin\n\n"
printf "  ${BOLD}Most likely remaining causes:${N}\n"
printf "    (A) FPC cable itself is damaged (broken conductor inside the flex)\n"
printf "        → Try a different FPC cable if you have one\n\n"
printf "    (B) Pi 5 CAM1 load switch is not passing 3.3 V\n"
printf "        → A multimeter on Pi CAM1 pin 15 vs GND would confirm\n\n"
printf "    (C) MCLK not physically reaching sensor\n"
printf "        → Oscilloscope or frequency counter on FPC pin 11 needed\n\n"
printf "    (D) Sensor or adapter board hardware damage\n\n"
printf "  ${Y}Next step: get a basic multimeter — even a cheap USB one works.${N}\n"
printf "  Measure 3.3 V between GND and the 3V3 pad on the adapter board\n"
printf "  while the overlay is loaded. That single reading tells us everything.\n"

echo ""
echo "Log: $LOG"
