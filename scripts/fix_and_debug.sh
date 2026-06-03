#!/bin/bash
# fix_and_debug.sh — end-to-end GenX320 troubleshooter for Raspberry Pi 5.
# Run with sudo from the repo root: sudo ./scripts/fix_and_debug.sh
#
# What it does (in order):
#   1.  Git pull latest changes
#   2.  Force-recompile the overlay and install to /boot/overlays/
#   3.  Remove any loaded genx320 overlay
#   4.  Try loading with default parameters — check dmesg
#   5.  Try with extended delays (rstn-delay-ms=600, startup-delay-us=900000)
#   6.  Try with always-on regulator
#   7.  If still failing: inject DIAG logging, rebuild driver, reinstall, reload
#   8.  Print final dmesg + summary

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
          echo -e "${CYAN}  $*${NC}"; \
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

LOG="fix_and_debug_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "Logging to $LOG"
echo "Started: $(date)"
echo "Kernel : $(uname -r)"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

unload_overlay() {
    if dtoverlay -l 2>/dev/null | grep -q genx320; then
        info "Removing loaded genx320 overlay..."
        dtoverlay -r genx320 2>/dev/null || true
        sleep 1
    fi
}

load_overlay() {
    local PARAMS="$1"
    local DESC="$2"
    info "Loading overlay: dtoverlay genx320${PARAMS:+,$PARAMS}  ($DESC)"
    unload_overlay
    dtoverlay genx320${PARAMS:+,$PARAMS} 2>&1
    sleep 3   # give driver time to probe
}

dmesg_genx320() {
    dmesg | grep -iE 'genx320|psee|cam[01]_reg|cam[01]_clk|inclk|rstn|eremoteio|boot.magic|power.on|power.off|failed.*sensor|sensor.*failed' | tail -20
}

probe_succeeded() {
    # Returns 0 (true) if a media entity for genx320 exists
    for d in {0..9}; do
        [ -e "/dev/media${d}" ] || continue
        media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320" && return 0
    done
    return 1
}

boot_magic_failed() {
    dmesg | grep -qi "boot magic\|failed to boot\|register read ret -121\|failed to power"
}

# ---------------------------------------------------------------------------
step "1. Git pull"
# ---------------------------------------------------------------------------
if git pull 2>&1; then
    ok "Repo up to date."
else
    warn "git pull failed — continuing with local files."
fi

# ---------------------------------------------------------------------------
step "2. Force-recompile overlay and install"
# ---------------------------------------------------------------------------
info "Touching DTS to force recompile..."
touch overlays/genx320-overlay.dts

info "Compiling genx320.dtbo..."
if make genx320.dtbo 2>&1; then
    ok "Compiled genx320.dtbo"
else
    fail "Failed to compile overlay. Is dtc installed? (sudo apt install device-tree-compiler)"
    exit 1
fi

info "Installing to /boot/overlays/..."
cp genx320.dtbo /boot/overlays/genx320.dtbo
ok "Installed /boot/overlays/genx320.dtbo"

# Verify rstn-delay-ms is in the compiled overlay
if dtc -I dtb -O dts genx320.dtbo 2>/dev/null | grep -q "rstn-delay-ms"; then
    ok "rstn-delay-ms parameter confirmed in compiled overlay."
else
    fail "rstn-delay-ms NOT found in compiled overlay — DTS change may not have saved."
    info "Contents of __overrides__ in compiled overlay:"
    dtc -I dtb -O dts genx320.dtbo 2>/dev/null | grep -A 30 "__overrides__" || true
fi

# ---------------------------------------------------------------------------
step "3. Attempt 1 — default parameters"
# ---------------------------------------------------------------------------
dmesg -c > /dev/null 2>&1 || true   # clear dmesg ring buffer if permitted
load_overlay "" "default"
echo ""
info "dmesg after load:"
dmesg_genx320

if probe_succeeded; then
    ok "SUCCESS with default parameters!"
    echo ""
    echo "Run: ./rp5_setup_v4l.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
step "4. Attempt 2 — extended delays (rstn-delay-ms=600, startup-delay-us=900000)"
# ---------------------------------------------------------------------------
dmesg -c > /dev/null 2>&1 || true
load_overlay "rstn-delay-ms=600,startup-delay-us=900000" "extended delays"
echo ""
info "dmesg after load:"
dmesg_genx320

if probe_succeeded; then
    ok "SUCCESS with extended delays!"
    echo ""
    echo "Add to /boot/firmware/config.txt to make permanent:"
    echo "  camera_auto_detect=0"
    echo "  dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=900000"
    exit 0
fi

# ---------------------------------------------------------------------------
step "5. Attempt 3 — always-on regulator + extended delays"
# ---------------------------------------------------------------------------
dmesg -c > /dev/null 2>&1 || true
load_overlay "always-on,rstn-delay-ms=600,startup-delay-us=900000" "always-on regulator"
echo ""
info "dmesg after load:"
dmesg_genx320

if probe_succeeded; then
    ok "SUCCESS with always-on regulator!"
    echo ""
    echo "Add to /boot/firmware/config.txt:"
    echo "  camera_auto_detect=0"
    echo "  dtoverlay=genx320,always-on,rstn-delay-ms=600,startup-delay-us=900000"
    exit 0
fi

# ---------------------------------------------------------------------------
step "6. Attempt 4 — cam0 slot (in case cable is in cam0)"
# ---------------------------------------------------------------------------
dmesg -c > /dev/null 2>&1 || true
load_overlay "cam0,rstn-delay-ms=600,startup-delay-us=900000" "cam0 slot"
echo ""
info "dmesg after load:"
dmesg_genx320

if probe_succeeded; then
    ok "SUCCESS on cam0!"
    echo ""
    echo "Add to /boot/firmware/config.txt:"
    echo "  camera_auto_detect=0"
    echo "  dtoverlay=genx320,cam0,rstn-delay-ms=600,startup-delay-us=900000"
    exit 0
fi

# ---------------------------------------------------------------------------
step "7. All overlay attempts failed — injecting DIAG logging and rebuilding"
# ---------------------------------------------------------------------------
SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    warn "drivers/genx320.c not found. Running make prepare first..."
    make prepare 2>&1
    SRC=$(find drivers -name "genx320.c" 2>/dev/null | head -1)
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    fail "Cannot find genx320.c even after make prepare. Aborting."
else
    ok "Found source: $SRC"

    if grep -q "DIAG power_on" "$SRC"; then
        ok "DIAG logging already present."
    else
        info "Injecting DIAG logging into $SRC..."
        cp "$SRC" "${SRC}.orig"

        python3 - "$SRC" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    s = line.rstrip()

    if re.search(r'regulator_enable\s*\(', s) and 'err' not in s.lower() and 'ret' not in s.lower():
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: regulator_enable called\\n");\n')
        i += 1; continue

    if re.search(r'regulator_bulk_enable\s*\(', s):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: regulator_bulk_enable called\\n");\n')
        i += 1; continue

    if re.search(r'clk_prepare_enable\s*\(', s):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: clk_prepare_enable called, rate=%lu\\n", clk_get_rate(genx320->inclk));\n')
        i += 1; continue

    if re.search(r'gpiod_set_value', s):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: reset GPIO set\\n");\n')
        i += 1; continue

    if re.search(r'\bmsleep\b|\busleep_range\b|\budelay\b', s):
        out.append(line)
        out.append('\tdev_info(dev, "DIAG power_on: delay done — starting I2C\\n");\n')
        i += 1; continue

    if re.search(r'(regmap_read|read_reg|i2c_smbus_read|genx320_read)\b', s):
        out.append('\tdev_info(dev, "DIAG identify: reading register (I2C addr 0x%02x)\\n", client->addr);\n')
        out.append(line)
        i += 1; continue

    out.append(line)
    i += 1

with open(path, 'w') as f:
    f.writelines(out)
print(f"Injected DIAG lines into {path}")
PYEOF

        if grep -q "DIAG" "$SRC"; then
            ok "DIAG lines injected."
            info "Injected at:"
            grep -n "DIAG" "$SRC"
        else
            warn "Injection produced no output — source structure unexpected."
            info "Showing power_on function for manual inspection:"
            awk '/genx320_power_on/,/^}/' "$SRC" | head -60
        fi
    fi

    info "Rebuilding driver..."
    if make psee_sensors 2>&1; then
        ok "Build succeeded."
    else
        fail "Build failed — check errors above."
        exit 1
    fi

    info "Reinstalling DKMS module..."
    dkms install psee_sensor_drivers/1.0.1 -k "$(uname -r)" 2>&1 || \
        warn "dkms install failed — trying direct insmod..."

    dmesg -c > /dev/null 2>&1 || true
    load_overlay "rstn-delay-ms=600,startup-delay-us=900000" "with DIAG logging"

    echo ""
    info "DIAG lines from dmesg:"
    dmesg | grep "DIAG" || warn "No DIAG lines — logging injection may not have hit the right functions."

    echo ""
    info "Full genx320 dmesg:"
    dmesg_genx320
fi

# ---------------------------------------------------------------------------
step "8. Final state"
# ---------------------------------------------------------------------------
echo ""
info "Overlay state:"
dtoverlay -l 2>/dev/null || true

echo ""
info "Regulator state:"
for r in /sys/class/regulator/regulator.*/name; do
    [ -f "$r" ] || continue
    NAME=$(cat "$r")
    DIR=$(dirname "$r")
    STATE=$(cat "$DIR/state" 2>/dev/null || echo "?")
    echo "$ANME" | grep -qiE 'cam|vdd' && echo "  $NAME : $STATE"
done
grep -iE 'cam|vdd' /sys/class/regulator/regulator.*/name 2>/dev/null | while read line; do
    FILE=$(echo "$line" | cut -d: -f1)
    DIR=$(dirname "$FILE")
    NAME=$(cat "$FILE")
    STATE=$(cat "$DIR/state" 2>/dev/null || echo "?")
    echo "  $NAME : $STATE"
done

echo ""
info "Clock state:"
grep -iE 'cam|gpclk|inclk' /sys/kernel/debug/clk/clk_summary 2>/dev/null || true

echo ""
info "I2C scan (camera buses):"
i2cdetect -l 2>/dev/null | grep -iE 'DesignWare|csi|cam' | while read line; do
    BUS=$(echo "$line" | awk '{print $1}' | sed 's/i2c-//')
    echo "  --- i2c-$BUS ---"
    i2cdetect -y "$BUS" 2>/dev/null || true
done

echo ""
if probe_succeeded; then
    ok "Sensor probed successfully! Run: ./rp5_setup_v4l.sh"
else
    fail "Sensor still not probing."
    echo ""
    echo "  Next steps to try manually:"
    echo "  1. Reseat the FPC cable at both ends (check contact orientation)."
    echo "  2. Confirm cable is in cam1 slot (or retry with cam0)."
    echo "  3. Scope the CLK pin on the FPC — should see 20 MHz."
    echo "  4. Scope NRST — should go HIGH after power-on."
    echo "  5. Share $LOG for further diagnosis."
fi

echo ""
echo "Log saved to: $LOG"
