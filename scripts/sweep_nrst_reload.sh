#!/bin/bash
# sweep_nrst_reload.sh — NRST GPIO sweep that reloads the overlay each time.
# Run with sudo from repo root: sudo ./scripts/sweep_nrst_reload.sh
#
# Why find_nrst.sh produced "no GPIO caused ACK":
#   That script held cam1_reg always-on but only loaded the overlay ONCE.
#   After the driver's probe() failed it called power_off() ->
#   clk_disable_unprepare() -> the RP1 stopped outputting 20 MHz on the
#   MCLK pin.  Every subsequent i2cget was run with no clock reaching the
#   sensor.  The GenX320 CANNOT respond to I2C without its reference clock.
#
# This script reloads the overlay fresh for every GPIO candidate.
# Each reload triggers:  power_on() -> regulator_enable -> clk_prepare_enable
#   -> MCLK pin active -> rstn-delay-ms wait -> I2C probe attempt.
# The GPIO candidate is driven HIGH BEFORE the overlay loads so NRST is
# already deasserted when the driver starts the I2C transaction.
#
# It also watches for ANY change in the error type, not just success.
# If a GPIO changes the error from EREMOTEIO to "boot magic" or "chip id"
# that confirms we found the reset pin even if the probe is still failing.

set -uo pipefail

R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }

LOG="sweep_nrst_reload_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1
KVER=$(uname -r)

echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  GenX320 NRST Sweep — overlay-reload method${N}\n"
printf "  Kernel: ${KVER}  |  $(date '+%Y-%m-%d %H:%M')\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""
info "Each GPIO is driven HIGH before the overlay loads."
info "MCLK is guaranteed active during every I2C probe attempt."
info "Any change in error type (not just success) is reported."
echo ""

# ── GPIO helpers via sysfs (works regardless of libgpiod version) ─────────────
CHIP_BASE=$(cat /sys/class/gpio/gpiochip0/base 2>/dev/null || echo 569)

gpio_high() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "$G"  > /sys/class/gpio/export              2>/dev/null || true
    echo "out" > /sys/class/gpio/gpio${G}/direction  2>/dev/null || true
    echo "1"   > /sys/class/gpio/gpio${G}/value      2>/dev/null || true
}
gpio_low() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "0"   > /sys/class/gpio/gpio${G}/value      2>/dev/null || true
}
gpio_release() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "in"  > /sys/class/gpio/gpio${G}/direction  2>/dev/null || true
    echo "$G"  > /sys/class/gpio/unexport            2>/dev/null || true
}
gpio_is_claimed() {
    local LINE=$1
    # Returns 0 (true) if the GPIO is owned by a kernel driver
    gpioinfo gpiochip0 2>/dev/null \
        | awk -v L="$LINE" '$0 ~ "line[[:space:]]+"L":" {print}' \
        | grep -q 'consumer=' && return 0 || return 1
}

probe_ok() {
    for d in 0 1 2 3 4 5; do
        [ -e "/dev/media${d}" ] || continue
        media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320" && return 0
    done
    return 1
}

# Classify the probe error from the most recent dmesg lines
error_type() {
    # Returns a short tag describing the failure
    local D
    D=$(dmesg 2>/dev/null | grep -iE 'genx320|psee|eremoteio|boot.magic|chip.id|Failed' | tail -5)
    if   echo "$D" | grep -qi "boot.magic";                then echo "BOOT_MAGIC_FAIL"
    elif echo "$D" | grep -qi "chip.id\|id.mismatch";      then echo "CHIP_ID_MISMATCH"
    elif echo "$D" | grep -qi "eremoteio\|ret -121";       then echo "EREMOTEIO"
    elif echo "$D" | grep -qi "Failed to power\|power.on"; then echo "POWER_ON_FAIL"
    elif probe_ok;                                          then echo "SUCCESS"
    else                                                         echo "UNKNOWN"
    fi
}

# ── baseline: what error are we getting right now? ────────────────────────────
printf "${BOLD}━━━━  STEP 1 / 3   Baseline error type  ━━━━${N}\n"
echo ""

dtoverlay -r genx320 2>/dev/null || true
sleep 1
dmesg -c > /dev/null 2>&1 || true

dtoverlay genx320,rstn-delay-ms=600,startup-delay-us=900000 2>/dev/null || true
sleep 6  # startup-delay-us (900ms) + probe + margin

BASELINE=$(error_type)
info "Baseline error with no extra GPIO: ${BASELINE}"

DIAG_LINES=$(dmesg | grep "DIAG" || true)
if [ -n "$DIAG_LINES" ]; then
    info "DIAG trace:"
    echo "$DIAG_LINES" | while IFS= read -r l; do note "  $l"; done
else
    warn "No DIAG lines — .ko may not have DIAG logging.  Run fix_driver_source.sh first."
fi
echo ""

dtoverlay -r genx320 2>/dev/null || true
sleep 1

# ── GPIO sweep with overlay reload ────────────────────────────────────────────
printf "${BOLD}━━━━  STEP 2 / 3   GPIO sweep with fresh overlay reload per candidate  ━━━━${N}\n"
echo ""
note "Format:  GPIO<N>  previous_error → new_error"
echo ""

# Priority order: Pi 5 CAM GPIO candidates, then full header sweep
# gpiochip0 lines 0-27 correspond to BCM GPIO0-GPIO27
CANDIDATES="4 5 6 17 22 23 24 25 26 27 2 3 7 8 9 10 11 12 13 14 15 16 18 19 20 21"

FOUND_GPIO=""
CHANGED_GPIO=""
CHANGED_ERROR=""

for LINE in $CANDIDATES; do
    # Skip GPIOs claimed by a kernel driver
    if gpio_is_claimed "$LINE"; then
        note "  GPIO${LINE}: skip (kernel-owned)"
        continue
    fi

    # Assert NRST candidate HIGH before the overlay loads
    gpio_high "$LINE"
    sleep 0.1  # let GPIO settle

    # Clear dmesg and load overlay fresh
    dmesg -c > /dev/null 2>&1 || true
    dtoverlay genx320,rstn-delay-ms=600,startup-delay-us=900000 2>/dev/null || true
    sleep 6  # wait for full probe attempt

    NEW_ERR=$(error_type)

    if [ "$NEW_ERR" = "SUCCESS" ]; then
        printf "  GPIO%-3s  %s → ${G}%s${N}  ← NRST FOUND!\n" "${LINE}" "${BASELINE}" "${NEW_ERR}"
        FOUND_GPIO="$LINE"
        dtoverlay -r genx320 2>/dev/null || true
        gpio_low "$LINE"
        gpio_release "$LINE"
        break
    elif [ "$NEW_ERR" != "$BASELINE" ]; then
        printf "  GPIO%-3s  %s → ${Y}%s${N}  ← error changed, likely NRST!\n" "${LINE}" "${BASELINE}" "${NEW_ERR}"
        CHANGED_GPIO="$LINE"
        CHANGED_ERROR="$NEW_ERR"
        # don't break — keep looking for full success
    else
        printf "  GPIO%-3s  %s → %s\n" "${LINE}" "${BASELINE}" "${NEW_ERR}"
    fi

    dtoverlay -r genx320 2>/dev/null || true
    gpio_low "$LINE"
    gpio_release "$LINE"
    sleep 1
done

# ── results ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━  STEP 3 / 3   Result  ━━━━${N}\n"
echo ""

if [ -n "$FOUND_GPIO" ]; then

    pass "NRST = GPIO${FOUND_GPIO}  (probe succeeded!)"
    echo ""
    printf "  Add to overlays/genx320-overlay.dts inside the genx320@3c node:\n\n"
    printf "    ${G}nreset-gpios = <&gpio ${FOUND_GPIO} GPIO_ACTIVE_HIGH>;${N}\n\n"
    printf "  Also uncomment the gpio.h include at the top of the DTS:\n"
    printf "    ${G}#include <dt-bindings/gpio/gpio.h>${N}\n\n"
    printf "  Then: make genx320.dtbo && sudo cp genx320.dtbo /boot/overlays/\n"
    printf "  Then: sudo ./scripts/probe_watch.sh\n"

elif [ -n "$CHANGED_GPIO" ]; then

    warn "GPIO${CHANGED_GPIO} changed the error: ${BASELINE} → ${CHANGED_ERROR}"
    note "This GPIO is likely NRST but the sensor still isn't fully probing."
    note ""
    note "The error changed to: ${CHANGED_ERROR}"
    if [ "$CHANGED_ERROR" = "BOOT_MAGIC_FAIL" ]; then
        note "BOOT_MAGIC_FAIL = sensor powered on and started booting but the"
        note "firmware boot-sequence didn't complete in time."
        note "Try larger startup-delay-us (1200000–2000000) or rstn-delay-ms (800)."
    elif [ "$CHANGED_ERROR" = "CHIP_ID_MISMATCH" ]; then
        note "CHIP_ID_MISMATCH = sensor responded on I2C! Wrong ID read."
        note "The sensor is alive.  Check if the adapter has a different chip ID."
    elif [ "$CHANGED_ERROR" = "POWER_ON_FAIL" ]; then
        note "POWER_ON_FAIL = regulator or clock failed to start."
    fi
    echo ""
    printf "  Try adding to the DTS:\n"
    printf "    ${Y}nreset-gpios = <&gpio ${CHANGED_GPIO} GPIO_ACTIVE_HIGH>;${N}\n"
    printf "  Then reload and run: sudo ./scripts/probe_watch.sh\n"

else

    fail "No GPIO changed the probe behaviour."
    echo ""
    printf "  The baseline error was: ${BASELINE}\n\n"
    printf "  Every GPIO candidate produced the same error.\n\n"

    if [ "$BASELINE" = "EREMOTEIO" ]; then
        printf "  ${BOLD}EREMOTEIO with every GPIO means:${N}\n"
        printf "  (A) The 20 MHz MCLK signal is not physically reaching the sensor.\n"
        printf "      The Pi/RP1 outputs it; something breaks the path to the die.\n"
        printf "      → Scope pin 11 on the CAM1 FPC connector: expect 20 MHz square wave.\n"
        printf "      → If no clock: FPC broken, wrong adapter revision, or bad contact.\n\n"
        printf "  (B) NRST is on a GPIO outside this scan range (gpiochip10).\n"
        printf "      → Run: sudo ./scripts/sweep_gpiochip10.sh  (generated below)\n\n"
        printf "  (C) The FPC cable is not making contact on SDA or SCL.\n"
        printf "      → Reseat the FPC at both ends. Check contacts face the right way.\n\n"
        printf "  (D) Sensor hardware damage.\n"
    fi

    echo ""
    printf "  ${BOLD}Generating sweep_gpiochip10.sh for the 2712 GPIO chip...${N}\n"

    # Auto-generate the gpiochip10 sweep script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cat > "${SCRIPT_DIR}/sweep_gpiochip10.sh" <<'GPIO10'
#!/bin/bash
# Auto-generated by sweep_nrst_reload.sh
# Sweeps gpiochip10 (BCM2712 / firmware GPIO) for the NRST pin.
set -uo pipefail

R='\033[0;31m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }

LOG="sweep_gpiochip10_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

CHIP10_BASE=$(cat /sys/class/gpio/gpiochip10/base 2>/dev/null || echo "")
if [ -z "$CHIP10_BASE" ]; then
    fail "gpiochip10 not found.  NRST is not on this chip."
    exit 1
fi
info "gpiochip10 base: $CHIP10_BASE"
CHIP10_NGPIO=$(cat /sys/class/gpio/gpiochip10/ngpio 2>/dev/null || echo 32)

gpio_high10() { local G=$((CHIP10_BASE + $1)); echo $G > /sys/class/gpio/export 2>/dev/null||true; echo out > /sys/class/gpio/gpio${G}/direction 2>/dev/null||true; echo 1 > /sys/class/gpio/gpio${G}/value 2>/dev/null||true; }
gpio_low10()  { local G=$((CHIP10_BASE + $1)); echo 0 > /sys/class/gpio/gpio${G}/value 2>/dev/null||true; }
gpio_rel10()  { local G=$((CHIP10_BASE + $1)); echo in > /sys/class/gpio/gpio${G}/direction 2>/dev/null||true; echo $G > /sys/class/gpio/unexport 2>/dev/null||true; }

probe_ok() { for d in 0 1 2 3 4 5; do [ -e "/dev/media${d}" ]||continue; media-ctl -p -d "$d" 2>/dev/null|grep -q genx320&&return 0; done; return 1; }

echo ""; info "Sweeping gpiochip10 lines 0-$((CHIP10_NGPIO-1)) ..."; echo ""

FOUND=""
for LINE in $(seq 0 $((CHIP10_NGPIO-1))); do
    CONS=$(gpioinfo gpiochip10 2>/dev/null|awk -v L=$LINE '$0 ~ "line[[:space:]]+"L":"{print}'|grep -oE 'consumer="[^"]+"'||echo "")
    [ -n "$CONS" ] && { printf "  line%-3s: skip (%s)\n" "$LINE" "$CONS"; continue; }

    gpio_high10 "$LINE"
    sleep 0.1
    dmesg -c >/dev/null 2>&1||true
    dtoverlay genx320,rstn-delay-ms=600,startup-delay-us=900000 2>/dev/null||true
    sleep 6
    if probe_ok; then
        printf "  line%-3s: ${G}SUCCESS — NRST = gpiochip10 line %s${N}\n" "$LINE" "$LINE"
        FOUND="$LINE"
        dtoverlay -r genx320 2>/dev/null||true; gpio_low10 "$LINE"; gpio_rel10 "$LINE"; break
    else
        ERR=$(dmesg|grep -iE 'eremoteio|boot.magic|chip.id'|tail -1||echo "no match")
        printf "  line%-3s: %s\n" "$LINE" "$ERR"
    fi
    dtoverlay -r genx320 2>/dev/null||true; gpio_low10 "$LINE"; gpio_rel10 "$LINE"; sleep 1
done

echo ""
if [ -n "$FOUND" ]; then
    pass "NRST = gpiochip10 line ${FOUND}"
    echo "  Add to DTS: nreset-gpios = <&gpio_2712 ${FOUND} GPIO_ACTIVE_HIGH>;"
else
    fail "No gpiochip10 line caused probe to succeed."
    echo "  NRST is not on gpiochip10.  Hardware issue (MCLK, FPC, damage) is likely."
fi
echo "Log: $LOG"
GPIO10
    chmod +x "${SCRIPT_DIR}/sweep_gpiochip10.sh"
    pass "Generated: scripts/sweep_gpiochip10.sh"
    echo ""
    echo "  Run: sudo ./scripts/sweep_gpiochip10.sh"
fi

echo ""
echo "Log: $LOG"
