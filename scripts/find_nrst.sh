#!/bin/bash
# find_nrst.sh — identify which Pi GPIO is the GenX320 NRST (reset) pin.
# Run with sudo from the repo root: sudo ./scripts/find_nrst.sh
#
# Why this script exists:
#   The DTS has no nreset-gpios. If the CCAM5 adapter wires NRST to a Pi GPIO
#   that defaults LOW, the sensor is frozen in hardware reset and will never
#   respond to I2C no matter how long you wait.
#
# What it does:
#   1. Loads overlay with always-on regulator so cam1_reg stays HIGH throughout.
#   2. Iterates through all plausible NRST GPIO candidates (GPIO4–GPIO27).
#   3. For each: drives it HIGH, waits 500 ms, attempts i2cget on the sensor bus.
#   4. If the sensor ACKs → prints the GPIO number and the DTS fix to apply.
#
# After running: if NRST is found, add nreset-gpios to the DTS and recompile.

set -uo pipefail

R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' B='\033[0;34m' N='\033[0m' BOLD='\033[1m'
pass() { printf "  ${G}[PASS]${N}  %s\n" "$*"; }
fail() { printf "  ${R}[FAIL]${N}  %s\n" "$*"; }
warn() { printf "  ${Y}[WARN]${N}  %s\n" "$*"; }
info() { printf "  ${B}[INFO]${N}  %s\n" "$*"; }
note() { printf "          %s\n" "$*"; }
bar()  { printf "${BOLD}────────────────────────────────────────────────────────────────────${N}\n"; }
hdr()  { echo ""; bar; printf "${BOLD}  %s${N}\n" "$*"; bar; }

LOG="find_nrst_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  GenX320 NRST GPIO Identification${N}\n"
printf "  Kernel: $(uname -r)  |  $(date '+%Y-%m-%d %H:%M')\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"

# ── prerequisites ─────────────────────────────────────────────────────────────
hdr "STEP 1 / 4   Prerequisites"

MISSING=0
for cmd in i2cdetect i2cget dtoverlay; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd found"
    else
        fail "$cmd not found"
        MISSING=1
    fi
done
if [ "$MISSING" = "1" ]; then
    echo "  Fix: sudo apt-get install i2c-tools"
    exit 1
fi

# Determine gpiochip0 base for sysfs GPIO control.
# On Pi 5 with RP1: typically 569.  Calculate dynamically.
CHIP_BASE=$(cat /sys/class/gpio/gpiochip0/base 2>/dev/null || echo "569")
info "gpiochip0 sysfs base offset: ${CHIP_BASE}"

# GPIO set/clear functions using sysfs (works on all Pi OS versions)
gpio_high() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "$G"  > /sys/class/gpio/export    2>/dev/null || true
    echo "out" > /sys/class/gpio/gpio${G}/direction 2>/dev/null || true
    echo "1"   > /sys/class/gpio/gpio${G}/value     2>/dev/null || true
}

gpio_low() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "0"   > /sys/class/gpio/gpio${G}/value     2>/dev/null || true
}

gpio_input() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    echo "in"  > /sys/class/gpio/gpio${G}/direction 2>/dev/null || true
    echo "$G"  > /sys/class/gpio/unexport           2>/dev/null || true
}

gpio_read() {
    local LINE=$1
    local G=$((CHIP_BASE + LINE))
    cat /sys/class/gpio/gpio${G}/value 2>/dev/null || echo "?"
}

# ── load overlay with always-on regulator ────────────────────────────────────
hdr "STEP 2 / 4   Load overlay with always-on regulator"

info "Removing any existing genx320 overlay..."
dtoverlay -r genx320 2>/dev/null || true
sleep 1

info "Loading: dtoverlay genx320,always-on,rstn-delay-ms=600,startup-delay-us=900000"
note "always-on keeps cam1_reg HIGH even after probe failure."
dtoverlay genx320,always-on,rstn-delay-ms=600,startup-delay-us=900000 2>&1 || {
    fail "dtoverlay failed — is the overlay compiled? Run: make genx320.dtbo && cp genx320.dtbo /boot/overlays/"
    exit 1
}
sleep 5   # allow probe attempt + startup-delay-us to complete

# Confirm cam1_reg is now enabled
CAM1_STATE=$(cat /sys/class/regulator/regulator.*/state 2>/dev/null | head -1 || echo "?")
for f in /sys/class/regulator/regulator.*/name; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "cam1_reg" ] || continue
    CAM1_STATE=$(cat "$(dirname "$f")/state" 2>/dev/null || echo "?")
done

if [ "$CAM1_STATE" = "enabled" ]; then
    pass "cam1_reg is ENABLED (always-on working)"
else
    warn "cam1_reg state: ${CAM1_STATE}"
    note "With always-on the regulator should stay enabled regardless of probe result."
    note "Continuing anyway — the test will still be valid."
fi

# Find sensor I2C bus
SENSOR_BUS_ADDR=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E "^[0-9]+-003c$" | head -1)
if [ -z "$SENSOR_BUS_ADDR" ]; then
    fail "genx320 device not found in /sys/bus/i2c/devices/ — overlay may not have loaded"
    exit 1
fi
SENSOR_BUS=$(echo "$SENSOR_BUS_ADDR" | cut -d- -f1)
pass "Sensor registered on i2c-${SENSOR_BUS} / 0x3c"

# ── baseline: confirm sensor still doesn't ACK without NRST driven ────────────
hdr "STEP 3 / 4   Baseline — sensor without NRST driven HIGH"

info "Testing i2c-${SENSOR_BUS} / 0x3c with no extra GPIO driven:"
if i2cget -y "$SENSOR_BUS" 0x3c 0x00 2>/dev/null; then
    pass "Sensor already ACKs without driving any GPIO!"
    note "NRST is not the issue — sensor is responding."
    note "The probe failure must have a different cause. Re-run status.sh."
    dtoverlay -r genx320 2>/dev/null || true
    exit 0
else
    info "No ACK (expected) — baseline confirmed."
    note "Power is ON (always-on), sensor still silent → NRST is likely held LOW."
fi

# ── GPIO sweep ────────────────────────────────────────────────────────────────
hdr "STEP 4 / 4   GPIO sweep — trying each NRST candidate"

echo ""
note "Order: most common Pi 5 camera reset GPIOs first, then full header sweep."
note "Each GPIO is driven HIGH for 600 ms, then i2cget tests 0x3c on i2c-${SENSOR_BUS}."
note "A real ACK = exactly one address responds.  Phantom buses show 30+."
echo ""

# Priority candidates based on Pi 5 camera connector assignments
PRIORITY="4 5 6 17 22 23 24 25 26 27"
REMAINDER="2 3 7 8 9 10 11 12 13 14 15 16 18 19 20 21"
CANDIDATES="${PRIORITY} ${REMAINDER}"

FOUND_GPIO=""

for LINE in $CANDIDATES; do
    # Skip GPIOs that are claimed by a kernel driver
    CONSUMER=$(gpioinfo gpiochip0 2>/dev/null \
        | awk -v L="$LINE" '$0 ~ "line[[:space:]]+"L":" {print}' \
        | grep -oE 'consumer="[^"]+"' || echo "")
    if [ -n "$CONSUMER" ]; then
        note "  GPIO${LINE}: skipping (${CONSUMER})"
        continue
    fi

    printf "  Testing GPIO%-3s ... " "${LINE}"

    # Drive HIGH
    gpio_high "$LINE"
    sleep 0.6

    # Test I2C
    if i2cget -y "$SENSOR_BUS" 0x3c 0x00 2>/dev/null; then
        printf "${G}ACK!${N}\n"
        FOUND_GPIO="$LINE"
        gpio_low "$LINE"
        gpio_input "$LINE"
        break
    else
        printf "no ACK\n"
        gpio_low "$LINE"
        gpio_input "$LINE"
    fi
done

# ── results ───────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BOLD}  RESULT${N}\n"
printf "${BOLD}══════════════════════════════════════════════════════════════════════${N}\n"
echo ""

if [ -n "$FOUND_GPIO" ]; then
    pass "NRST GPIO FOUND: GPIO${FOUND_GPIO}  (gpiochip0 line ${FOUND_GPIO})"
    echo ""
    printf "  ${BOLD}Add this property to overlays/genx320-overlay.dts${N}\n"
    printf "  inside the genx320@3c node:\n\n"
    printf "  ${G}    nreset-gpios = <&gpio ${FOUND_GPIO} GPIO_ACTIVE_HIGH>;${N}\n\n"
    printf "  Then rebuild and install the overlay:\n"
    printf "    make genx320.dtbo\n"
    printf "    sudo cp genx320.dtbo /boot/overlays/genx320.dtbo\n"
    printf "    sudo dtoverlay -r genx320\n"
    printf "    sudo dtoverlay genx320\n\n"
    printf "  And uncomment the gpio.h include at the top of the DTS:\n"
    printf "  ${G}    #include <dt-bindings/gpio/gpio.h>${N}\n"
else
    fail "No GPIO caused the sensor to ACK."
    echo ""
    printf "  This means either:\n"
    printf "  ${BOLD}(A) The 20 MHz clock is not physically reaching the sensor${N}\n"
    printf "      cam1_clk is programmed on the Pi/RP1 side, but the MCLK signal\n"
    printf "      may not be making it to the sensor's CLK pin on the FPC.\n"
    printf "      Without its reference clock, the GenX320 will not respond to I2C.\n"
    printf "      → Check CLK pin with oscilloscope: should show 20 MHz when\n"
    printf "        the overlay is loaded. Typical amplitude: 1.8 V p-p.\n\n"
    printf "  ${BOLD}(B) NRST is on a GPIO not in the scan range${N}\n"
    printf "      Some adapters use an I2C expander or a GPIO outside the 40-pin\n"
    printf "      header (e.g., on gpiochip10). Check your adapter schematic.\n\n"
    printf "  ${BOLD}(C) FPC physical issue${N}\n"
    printf "      Reseat the FPC at both ends. Contacts must face the correct\n"
    printf "      direction at both the Pi connector and the sensor adapter.\n\n"
    printf "  ${BOLD}(D) Sensor hardware damage${N}\n"
    printf "      If all else fails, the sensor die or FPC may be damaged.\n"
fi

# Cleanup
dtoverlay -r genx320 2>/dev/null || true

echo ""
echo "Log: $LOG"
