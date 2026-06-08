#!/bin/bash
# force_power_test.sh — manually assert cam1_reg GPIO and test sensor I2C.
# Run with sudo from the repo root: sudo ./scripts/force_power_test.sh
#
# Context from May-26 log:
#   - cam1_reg = gpiochip0 line 46 (CD1_IO0_MICCLK, gpio-615), active-high
#   - cam0_reg = gpiochip0 line 34 (CD0_IO0_MICCLK, gpio-603), active-high
#   - cam1_clk is 20 MHz and was already prepared/enabled
#   - Sensor registered at i2c-11 (DesignWare, address 0x3c) but got EREMOTEIO
#
# This script bypasses the kernel regulator framework and directly drives the
# cam_reg GPIO to hold power on while we do a manual I2C probe.  Use it to
# determine whether the EREMOTEIO is a timing problem (sensor not ready) or a
# hardware problem (no ACK even with sustained power).

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
step() { echo -e "\n${CYAN}━━━━  $*  ━━━━${NC}\n"; }

LOG="force_power_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "force_power_test.sh  kernel=$(uname -r)  $(date)"
echo ""

# gpiochip0 line numbers from the May-26 debug log
CAM1_REG_CHIP="gpiochip0"
CAM1_REG_LINE=46   # CD1_IO0_MICCLK — cam1 3.3 V enable

CAM0_REG_CHIP="gpiochip0"
CAM0_REG_LINE=34   # CD0_IO0_MICCLK — cam0 3.3 V enable

# GenX320 chip ID register and expected value (from Prophesee datasheet)
# 0x0000 = devid register, expected = 0x30501003
CHIP_ID_REG="0x0000"

# ---------------------------------------------------------------------------
step "0. Prerequisites"
# ---------------------------------------------------------------------------
for cmd in gpioset gpioget i2cget i2cdetect; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "Missing tool: $cmd"
        echo "  sudo apt-get install gpiod i2c-tools"
        exit 1
    fi
done
ok "gpiod and i2c-tools present."

# ---------------------------------------------------------------------------
step "1. Unload overlay (release kernel's hold on cam_reg GPIO)"
# ---------------------------------------------------------------------------
if dtoverlay -l 2>/dev/null | grep -q genx320; then
    info "Removing genx320 overlay so kernel releases the GPIO..."
    dtoverlay -r genx320 2>/dev/null || true
    sleep 1
    ok "Overlay removed."
else
    info "genx320 overlay not loaded (GPIO should be free)."
fi

# ---------------------------------------------------------------------------
step "2. Identify camera I2C buses"
# ---------------------------------------------------------------------------
info "All I2C buses:"
i2cdetect -l 2>/dev/null

# On Pi 5 with kernel 6.12, the CSI camera buses are 107d508200.i2c and 107d508280.i2c
# They appear as i2c-13 and i2c-14 in the May-26 log.
# The DesignWare bus i2c-11 is where the kernel registered genx320@3c.
CAM_BUSES=$(i2cdetect -l 2>/dev/null | grep -E 'DesignWare|107d508' | awk '{print $1}' | sed 's/i2c-//')
DW_BUS=$(i2cdetect -l 2>/dev/null | grep 'DesignWare' | awk '{print $1}' | sed 's/i2c-//' | head -1)

echo ""
info "DesignWare / CSI buses: ${CAM_BUSES:-none found}"

# ---------------------------------------------------------------------------
step "3. Baseline I2C scan (power OFF)"
# ---------------------------------------------------------------------------
info "Scanning for 0x3c with cam_reg power OFF (baseline):"
for BUS in $CAM_BUSES; do
    echo "  i2c-${BUS}:"
    i2cget -y "$BUS" 0x3c 0x00 2>&1 | head -2 || true
done

# ---------------------------------------------------------------------------
step "4. Assert cam1_reg GPIO (force 3.3 V to cam1 connector)"
# ---------------------------------------------------------------------------
info "Driving ${CAM1_REG_CHIP} line ${CAM1_REG_LINE} HIGH (cam1_reg enable)..."
warn "This bypasses the kernel regulator — do not leave running for more than 10 s."

# gpioset releases the line when the process exits; run in background with a timeout
gpioset --mode=time --sec=8 "${CAM1_REG_CHIP}" "${CAM1_REG_LINE}=1" &
GPIO_PID=$!

info "cam1_reg GPIO asserted (PID $GPIO_PID).  Waiting 2 s for sensor power-up..."
sleep 2

# Verify GPIO is high
GPIO_VAL=$(gpioget "${CAM1_REG_CHIP}" "${CAM1_REG_LINE}" 2>/dev/null || echo "?")
info "GPIO ${CAM1_REG_LINE} reads: ${GPIO_VAL}"

# ---------------------------------------------------------------------------
step "5. I2C probe with cam1_reg forced ON"
# ---------------------------------------------------------------------------
info "Scanning all cam buses for 0x3c (power forced on):"
FOUND=0
for BUS in $CAM_BUSES; do
    echo ""
    info "  i2c-${BUS} quick probe at 0x3c:"
    if i2cget -y "$BUS" 0x3c 0x00 2>&1; then
        ok "  ACK on i2c-${BUS}! Sensor is responding."
        FOUND=1
    else
        echo "  (no ACK or error — expected if clock not running)"
    fi
done

if [ "$FOUND" = "0" ]; then
    info "No ACK with cam1_reg forced. Waiting an extra 3 s (slow boot)..."
    sleep 3
    for BUS in $CAM_BUSES; do
        if i2cget -y "$BUS" 0x3c 0x00 2>&1; then
            ok "  ACK on i2c-${BUS} after extended wait!"
            FOUND=1
        fi
    done
fi

# ---------------------------------------------------------------------------
step "6. Also try cam0_reg"
# ---------------------------------------------------------------------------
if [ "$FOUND" = "0" ]; then
    info "Trying cam0_reg (in case cable is in cam0 slot)..."
    gpioset --mode=time --sec=8 "${CAM0_REG_CHIP}" "${CAM0_REG_LINE}=1" &
    GPIO0_PID=$!
    sleep 2
    for BUS in $CAM_BUSES; do
        if i2cget -y "$BUS" 0x3c 0x00 2>&1; then
            ok "ACK on i2c-${BUS} with cam0_reg!  Cable is in cam0 slot."
            FOUND=1
        fi
    done
    wait "$GPIO0_PID" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "7. Release GPIO and summarise"
# ---------------------------------------------------------------------------
wait "$GPIO_PID" 2>/dev/null || true
info "GPIO released."

echo ""
if [ "$FOUND" = "1" ]; then
    ok "Sensor ACKs on I2C when power is forced on."
    echo ""
    echo "  Conclusion: the sensor hardware is alive. The probe failure is a"
    echo "  timing problem — regulator startup or reset delay is too short."
    echo ""
    echo "  Fix: load the overlay with longer delays:"
    echo "    sudo dtoverlay genx320,rstn-delay-ms=600,startup-delay-us=1200000"
    echo "  Or make permanent in /boot/firmware/config.txt:"
    echo "    camera_auto_detect=0"
    echo "    dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=1200000"
else
    fail "Sensor did NOT ACK on I2C even with regulator forced on."
    echo ""
    echo "  Conclusions:"
    echo "  (A) Clock not reaching sensor — 20 MHz GPCLK may not be wired to"
    echo "      the FPC CLK pin when overlay is not loaded."
    echo "      Check cam1_clk state: grep cam1_clk /sys/kernel/debug/clk/clk_summary"
    echo ""
    echo "  (B) Reset (NRST) held low — the sensor requires NRST to go HIGH."
    echo "      The DTS has no nreset-gpios defined; if NRST is floating or"
    echo "      tied low on the CCAM5 adapter, the sensor will never boot."
    echo "      Measure NRST pin on the FPC connector with a multimeter."
    echo ""
    echo "  (C) Wrong cam slot — try the other connector."
    echo ""
    echo "  (D) Hardware damage to sensor or FPC."
fi

echo ""
echo "Log: $LOG"
