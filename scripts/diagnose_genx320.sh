#!/bin/bash
# Diagnostic script for GenX320 / CCAM5 bring-up on Raspberry Pi 5.
# Run with sudo for full I2C bus access: sudo ./scripts/diagnose_genx320.sh
#
# Interprets dmesg, I2C bus state, and media topology to distinguish:
#   (a) no-power / no-contact  → fix FPC / cam_reg
#   (b) powered but no ACK    → fix clock, reset timing, or sensor damage

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
sep()  { echo ""; echo "------------------------------------------------------------------------"; echo ""; }

echo "==================================================================="
echo " GenX320 / CCAM5 bring-up diagnostic — $(date)"
echo "==================================================================="

# ---------------------------------------------------------------------------
# 1. Kernel module
# ---------------------------------------------------------------------------
sep
info "1. Kernel module"
if lsmod | grep -qE "^genx320"; then
    ok "genx320 module loaded."
else
    fail "genx320 module NOT loaded."
    echo "   → Run: sudo modprobe genx320-driver"
    echo "   → Or verify DKMS with: dkms status"
fi

# ---------------------------------------------------------------------------
# 2. DKMS status
# ---------------------------------------------------------------------------
sep
info "2. DKMS status"
dkms status 2>/dev/null | grep -i "psee\|genx320" || warn "No psee_sensor_drivers DKMS entry found."

# ---------------------------------------------------------------------------
# 3. Overlay / device-tree node
# ---------------------------------------------------------------------------
sep
info "3. Device-tree overlay"
DT_FOUND=0
for path in /proc/device-tree/soc/i2c*/genx320* /proc/device-tree/aliases/genx320 \
            /sys/bus/i2c/devices/*/of_node/compatible; do
    if ls "$path" 2>/dev/null | head -1 | grep -q .; then
        DT_FOUND=1
        break
    fi
done
# broader search
if find /proc/device-tree -name "compatible" -exec grep -l "psee,genx320" {} \; 2>/dev/null | grep -q .; then
    DT_FOUND=1
fi
if [ "$DT_FOUND" = "1" ]; then
    ok "genx320 DT node found in device-tree."
else
    fail "genx320 DT node NOT found."
    echo "   → Load overlay: sudo dtoverlay genx320"
    echo "   → For cam0 slot: sudo dtoverlay genx320,cam0"
    echo "   → Persistent (config.txt): camera_auto_detect=0 + dtoverlay=genx320[,cam0]"
fi

# ---------------------------------------------------------------------------
# 4. Full dmesg snippet: power / clock / reset / I2C near probe
# ---------------------------------------------------------------------------
sep
info "4. dmesg — power / clock / reset / I2C (last 60 matching lines)"
echo "--- dmesg snippet ---"
dmesg | grep -iE \
    'genx320|psee|cam[01]_reg|cam[01]_clk|rp1.cfe|regulator.*cam|cam.*regul|inclk|rstn|reset.*cam|cam.*reset|i2c.*3c|3c.*i2c|eremoteio' \
    | tail -60 || true
echo "--- end snippet ---"

# ---------------------------------------------------------------------------
# 5. Power-rail diagnosis
# ---------------------------------------------------------------------------
sep
info "5. Power-rail state (from dmesg)"

POWER_OK=0
REG_SEEN=0
CLK_SEEN=0
EREMOTEIO_SEEN=0

if dmesg | grep -qiE 'cam[01]_reg.*enabl|enabl.*cam[01]_reg|cam[01]_reg.*on|regulator.*enable.*cam'; then
    REG_SEEN=1
fi
if dmesg | grep -qiE 'cam[01]_clk|inclk|20000000'; then
    CLK_SEEN=1
fi
if dmesg | grep -q "register read ret -121"; then
    EREMOTEIO_SEEN=1
fi

if [ "$EREMOTEIO_SEEN" = "1" ]; then
    fail "Sensor did not ACK on I2C (register read ret -121 = -EREMOTEIO)."
    if [ "$REG_SEEN" = "1" ]; then
        ok "cam_reg enable seen → power likely reached the module."
        POWER_OK=1
        warn "Sensor is powered but silent. Likely causes:"
        echo "   (A) 20 MHz inclk not reaching sensor — the RP1 GPCLK may not"
        echo "       be driving the clock pin.  Verify with oscilloscope on"
        echo "       CLK pin of the camera FPC connector."
        echo "   (B) NRST stuck LOW — floating or Pi GPIO driving it low."
        echo "       Check dmesg for 'reset' or 'gpio' messages."
        echo "   (C) rstn-delay-ms too short — sensor needs more post-reset time."
        echo "       Try: dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=800000"
        echo "   (D) Sensor damage from prior overcurrent event."
        echo "   (E) FPC orientation wrong at one end of the Adafruit adapter."
    else
        fail "No cam_reg enable seen in dmesg."
        warn "Power likely NOT reaching the module. Likely causes:"
        echo "   (A) FPC not seated — inspect both ends (contacts face correct side)."
        echo "   (B) Wrong CSI slot — overlay loaded for cam1 but cable in cam0 or vice versa."
        echo "   (C) cam_reg stuck off — try: dtoverlay=genx320,always-on"
        echo "   (D) Pi 5 peripheral-power warning (previous short) — check dmesg"
        echo "       for 'power' or 'overcurrent' near boot."
    fi
else
    if [ "$REG_SEEN" = "1" ]; then
        ok "cam_reg enable seen, no -EREMOTEIO. Driver may not have probed yet."
    else
        warn "No -EREMOTEIO and no cam_reg message — driver may not have probed."
        echo "   → Is the overlay loaded? Run: sudo dtoverlay genx320"
    fi
fi

# ---------------------------------------------------------------------------
# 6. I2C bus scan
# ---------------------------------------------------------------------------
sep
info "6. I2C bus scan for sensor at 0x3c"

# Pi 5: camera I2C buses are typically high-numbered (i2c-10, i2c-11, etc.)
# and show as "Synopsys DesignWare I2C adapter" in i2cdetect -l.
ALL_BUSES=$(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//')
CAM_BUSES=$(i2cdetect -l 2>/dev/null | grep -iE 'DesignWare|bcm|csi|cam|vc4' | awk '{print $1}' | sed 's/i2c-//')

if [ -z "$ALL_BUSES" ]; then
    fail "i2cdetect not available or no I2C buses found. Is i2c-tools installed?"
    echo "   → sudo apt install i2c-tools"
else
    FOUND_03C=0
    for BUS in $ALL_BUSES; do
        SCAN=$(i2cdetect -y "$BUS" 2>/dev/null) || continue
        if echo "$SCAN" | grep -qE ' 3c | 3c$'; then
            ok "Device ACKs at 0x3c on i2c-${BUS}!"
            FOUND_03C=1
            echo "$SCAN"
        fi
    done

    if [ "$FOUND_03C" = "0" ]; then
        fail "No device found at 0x3c on any I2C bus."
        if [ "$POWER_OK" = "1" ]; then
            echo "   Power appears OK — sensor is not responding to I2C at all."
        fi
        echo ""
        echo "   Camera I2C buses (likely candidates):"
        if [ -n "$CAM_BUSES" ]; then
            for BUS in $CAM_BUSES; do
                echo "   → i2c-${BUS}:"
                i2cdetect -y "$BUS" 2>/dev/null | head -5 || true
            done
        else
            echo "   (Could not identify camera-specific buses; scan all above.)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. Media topology
# ---------------------------------------------------------------------------
sep
info "7. Media controller topology"
ENTITY_FOUND=0
for d in {0..9}; do
    if ! [ -e "/dev/media${d}" ]; then continue; fi
    if media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320"; then
        ok "genx320 entity found in /dev/media${d} — driver probed successfully!"
        ENTITY_FOUND=1
        media-ctl -p -d "$d" 2>/dev/null
        break
    fi
done
if [ "$ENTITY_FOUND" = "0" ]; then
    fail "genx320 entity not present in any /dev/media* device."
    echo "   This confirms the sensor has not successfully probed."
fi

# ---------------------------------------------------------------------------
# 8. Summary and next steps
# ---------------------------------------------------------------------------
sep
echo "==================================================================="
echo " Summary"
echo "==================================================================="
[ "$EREMOTEIO_SEEN" = "1" ] && [ "$POWER_OK" = "1" ] && {
    echo " Hypothesis: sensor powered, but clock or reset not arriving."
    echo " Next steps (in order):"
    echo "   1. Oscilloscope / LA: confirm 20 MHz on CLK pin of FPC at cam1 header."
    echo "   2. Confirm NRST pin floats HIGH (not being driven low by Pi GPIO)."
    echo "   3. Try larger delays: dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=900000"
    echo "   4. Check FPC contacts face the correct direction at both adapter ends."
    echo "   5. Enable probe-debug logging: see patches/0001-genx320-probe-debug-logging.patch"
    echo "      then: echo 'module genx320_driver +p' | sudo tee /sys/kernel/debug/dynamic_debug/control"
}
[ "$EREMOTEIO_SEEN" = "1" ] && [ "$POWER_OK" = "0" ] && {
    echo " Hypothesis: power/contact problem."
    echo " Next steps:"
    echo "   1. Reseat FPC — contacts must face the correct side at BOTH ends."
    echo "   2. Confirm dtoverlay uses the right slot (cam0 or cam1)."
    echo "   3. Multimeter: measure 3.3 V on camera connector 3V3 pin when powered."
    echo "   4. Try always-on regulator: dtoverlay=genx320,always-on"
}
[ "$ENTITY_FOUND" = "1" ] && {
    echo " Sensor probed OK. If streaming fails, run ./rp5_setup_v4l.sh next."
}
echo ""
