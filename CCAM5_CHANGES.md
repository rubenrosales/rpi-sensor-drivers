# GenX320 / CCAM5 bring-up changes — manual recreation guide

## Context

Debugging a Prophesee GenX320 CCAM5 module (from an AMD Kria KV260 kit)
on Raspberry Pi 5.  The driver probes but fails immediately with
`register read ret -121` (-EREMOTEIO), meaning the sensor at I2C address
`0x3c` does not ACK.

Four files were changed from the upstream `main` branch.  Apply them in
any order; commit once; push to `claude/zen-heisenberg-56Ves`.

---

## File 1 — `overlays/genx320-overlay.dts` (modify)

### What changed and why

| Change | Reason |
|--------|--------|
| Added `assigned-clocks` / `assigned-clock-rates` to sensor node | On Pi 5, the RP1 clock driver can re-initialise and reset the GPCLK rate after the bootloader sets it. Adding these to the *consumer* node (the sensor) tells the Linux clock framework to re-program 20 MHz at driver probe time — belt-and-suspenders alongside the existing `clock-frequency` on `cam1_clk`. |
| Added `"assigned-clocks:0="` to the `cam0` override | Without this, selecting `cam0` leaves `assigned-clocks` pointing at `cam1_clk` instead of `cam0_clk`. |
| Added `rstn-delay-ms` override parameter | Users can now tune the post-reset delay without recompiling: `dtoverlay=genx320,rstn-delay-ms=600` |
| Added `startup-delay-us` override parameter | Same for the power-supply startup delay: `dtoverlay=genx320,startup-delay-us=800000` |
| Added explanatory comments | Documents the CCAM5 / RP1 clock rationale for future readers. |

### Full replacement content

```dts
// SPDX-License-Identifier: GPL-2.0-only
// Definitions for GenX320 camera module on VC I2C bus
/dts-v1/;
/plugin/;

// #include <dt-bindings/gpio/gpio.h>

/{
	compatible = "brcm,bcm2835";

	fragment@0 {
		target = <&i2c0if>;
		__overlay__ {
			status = "okay";
			clock-frequency = <400000>;
		};
	};

	clk_frag: fragment@1 {
		target = <&cam1_clk>;
		__overlay__ {
			status = "okay";
			clock-frequency = <20000000>;
		};
	};

	fragment@2 {
		target = <&i2c0mux>;
		__overlay__ {
			status = "okay";
		};
	};

	reg_frag: fragment@5 {
		target = <&cam1_reg>;
		cam_reg: __overlay__ {
			/* 500 ms lets CCAM5 on-module regulators stabilise before
			 * the driver's first I2C access. Increase via dtoverlay
			 * startup-delay-us=<N> if probe still times out. */
			startup-delay-us = <500000>;
		};
	};

	reg_alwayson_frag: fragment@99 {
		target = <&cam1_reg>;
		__dormant__ {
			regulator-always-on;
		};
	};

	i2c_frag: fragment@100 {
		target = <&i2c_csi_dsi>;
		__overlay__ {
			#address-cells = <1>;
			#size-cells = <0>;
			status = "okay";
			clock-frequency = <400000>;
			genx320: genx320@3c {
				compatible = "psee,genx320";
				reg = <0x3c>;
				status = "okay";

				clocks = <&cam1_clk>;
				clock-names = "inclk";

				/* Ask the Linux clock framework to program the RP1
				 * GPCLK to 20 MHz at probe time.  The Pi firmware
				 * already reads clock-frequency above before Linux
				 * boots, but on Pi 5 the RP1 clock driver can reset
				 * the rate unless assigned-clock-rates is also set. */
				assigned-clocks = <&cam1_clk>;
				assigned-clock-rates = <20000000>;

				vadd-supply = <&cam1_reg>;
				vddd1-supply = <&cam_dummy_reg>;
				vddd2-supply = <&cam_dummy_reg>;

				rotation = <180>;
				orientation = <2>;

				rstn-delay-ms = <385>;

				port {
					genx320_0: endpoint {
						remote-endpoint = <&csi_ep>;
						clock-lanes = <0>;
						data-lanes = <1>;
						clock-noncontinuous;
						link-frequencies = /bits/ 64 <750000000>;
					};
				};
			};
		};
	};

	csi_frag: fragment@101 {
		target = <&csi1>;
		csi: __overlay__ {
			status = "okay";
			brcm,media-controller;

			port {
				csi_ep: endpoint {
					remote-endpoint = <&genx320_0>;
					clock-lanes = <0>;
					data-lanes = <1>;
					clock-noncontinuous;
				};
			};
		};
	};

	__overrides__ {
		rotation = <&genx320>,"rotation:0";
		orientation = <&genx320>,"orientation:0";
		media-controller = <&csi>,"brcm,media-controller?";
		cam0 = <&i2c_frag>, "target:0=",<&i2c_csi_dsi0>,
				<&csi_frag>, "target:0=",<&csi0>,
				<&clk_frag>, "target:0=",<&cam0_clk>,
				<&reg_frag>, "target:0=",<&cam0_reg>,
				<&reg_alwayson_frag>, "target:0=",<&cam0_reg>,
				<&genx320>, "clocks:0=",<&cam0_clk>,
				<&genx320>, "assigned-clocks:0=",<&cam0_clk>,
				<&genx320>, "vadd-supply:0=",<&cam0_reg>;
		always-on = <0>, "+99";
		/* Timing knobs — increase if the sensor still doesn't respond.
		 * Example: dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=800000 */
		rstn-delay-ms    = <&genx320>,"rstn-delay-ms:0";
		startup-delay-us = <&cam_reg>,"startup-delay-us:0";
	};
};
```

---

## File 2 — `Makefile` (modify)

### What changed and why

| Change | Reason |
|--------|--------|
| Added `PROBE_DEBUG ?= 0` / `PATCHES_DIR` variables | Enables optional probe-debug build without changing the default workflow. |
| Added patch-apply block inside `prepare` | `make prepare PROBE_DEBUG=1` clones the drivers and applies the debug logging patch in one step. |
| Added `probe-debug` target | `make probe-debug` re-clones + patches + builds in one command. |
| Added `diagnose` target | `make diagnose` runs the diagnostic script with sudo. |

### Full replacement content

```makefile

# Kernel version
kernelver ?= $(shell uname -r)

# Paths
OVERLAY_DIR := overlays
DTB_OUTPUT := /boot/overlays
KERNEL_SRC := /lib/modules/$(kernelver)/build
EXTRA_CFLAGS := "-DOMIT_PSEE_FORMATS"

# Optional probe-debug patch.  Set PROBE_DEBUG=1 on the make prepare command
# line to apply patches/0001-genx320-probe-debug-logging.patch after cloning.
# Example: make prepare PROBE_DEBUG=1
PROBE_DEBUG ?= 0
PATCHES_DIR := patches

# Targets
all: psee_sensors genx320.dtbo imx636.dtbo

drivers:
	@test -d drivers || (echo "Error: drivers not found. Run 'make prepare' first." && exit 1)

prepare:
	@echo "Cloning Drivers..."
	git clone --branch kernel-6.12 https://github.com/prophesee-ai/linux-sensor-drivers.git drivers
	git -C drivers checkout 7165d5e69ebed78dcc63b36e1d0f451c42aa7aaa
ifeq ($(PROBE_DEBUG),1)
	@echo "Applying probe-debug logging patch..."
	@patch -d drivers -p1 --fuzz=3 \
		< $(PATCHES_DIR)/0001-genx320-probe-debug-logging.patch \
		|| (echo "WARNING: patch did not apply cleanly -- see .rej files in drivers/." \
		    echo "Apply the logging additions manually as described in the patch comments."; true)
	@touch drivers/.probe-debug-patched
endif

psee_sensors: drivers
	@echo "Building PSEE Sensors Driver..."
	$(MAKE) -C drivers KERNEL_SRC=$(KERNEL_SRC) EXTRA_CFLAGS=$(EXTRA_CFLAGS)
	# dkms needs them in this place
	cp drivers/*.ko .

%.dtbo: overlays/%-overlay.dts
	@echo "Compiling Device Tree Overlays..."
	dtc -@ -Hepapr -I dts -O dtb -o $@ $<

install: all
	@echo "Installing PSEE Sensors Driver..."
	$(MAKE) -C drivers modules_install KERNEL_SRC=$(KERNEL_SRC) EXTRA_CFLAGS=$(EXTRA_CFLAGS)
	@echo "Installing Device Tree Overlays for Genx320..."
	install -m 644 genx320.dtbo $(DTB_OUTPUT)
	install -m 644 imx636.dtbo $(DTB_OUTPUT)
	depmod -a

uninstall:
	@echo "Removing PSEE Sensors Driver..."
	rm -rf "$(DTB_OUTPUT)/genx320.dtbo"
	rm -rf "$(DTB_OUTPUT)/imx636.dtbo"
	rm -rf "/lib/modules/$(kernelver)/updates/genx320-driver.ko.xz"
	rm -rf "/lib/modules/$(kernelver)/updates/imx636.ko.xz"
	depmod -a

clean: drivers
	@echo "Cleaning up..."
	$(MAKE) -C drivers clean
	rm -rf *.dtbo
	rm -rf *.ko

# Re-clone with the probe-debug patch applied.
# Tears down any existing drivers/ clone first.
probe-debug:
	rm -rf drivers
	$(MAKE) prepare PROBE_DEBUG=1
	$(MAKE) psee_sensors

# Run the bring-up diagnostic (requires sudo for i2cdetect).
diagnose:
	sudo bash scripts/diagnose_genx320.sh

.PHONY: all install uninstall clean probe-debug diagnose
```

> **Note:** Makefile targets use real tabs, not spaces.  If copying from
> this Markdown, ensure your editor inserts tabs before recipe lines.

---

## File 3 — `patches/0001-genx320-probe-debug-logging.patch` (new file)

Create the `patches/` directory and add this file.

### What it does

Annotated patch for `drivers/genx320/genx320.c` (in the cloned
`linux-sensor-drivers` repo).  Adds `dev_info()` calls at each step of
`genx320_power_on()` and before the first I2C read, so `dmesg | grep DIAG`
shows exactly which steps completed before `-121`.

This is **not** a standard `patch -p1` patch — it is annotated with
prose describing where each hunk goes, because the exact line numbers
are unknown without cloning first.  Apply with `make probe-debug` (which
tries `patch --fuzz=3`) or manually as described in the file.

### File content

```
From: rpi-sensor-drivers fork <noreply@example.com>
Subject: [PATCH] genx320: add probe-time diagnostic logging

Add dev_info() calls at each step inside genx320_power_on() and
immediately before the first I2C register read in the boot-magic /
chip-ID check.  This lets dmesg reveal whether regulators, the 20 MHz
inclk, and the reset GPIO were exercised before -EREMOTEIO, which
narrows "no power/contact" vs "powered but sensor silent" without a
scope.

Applies to: prophesee-ai/linux-sensor-drivers @ 7165d5e (kernel-6.12)

If the patch rejects, apply the annotated hunks manually -- the comments
below each hunk describe exactly what to look for and where to insert.

---
 genx320/genx320.c | ~50 lines added
---

--- a/genx320/genx320.c
+++ b/genx320/genx320.c

===========================================================================
HUNK 1 -- genx320_power_on(): log each rail + clock enable
===========================================================================
Context: Find the function that enables regulators and calls
clk_prepare_enable(genx320->inclk).  Add dev_info lines after each
successful enable so dmesg confirms the sequence completed.

--- a/genx320/genx320.c
+++ b/genx320/genx320.c
@@ genx320_power_on @@
 	ret = regulator_enable(genx320->vadd);
 	if (ret) {
 		dev_err(dev, "Failed to enable vadd regulator: %d\n", ret);
-		return ret;
+		goto err_vadd;
 	}
+	dev_info(dev, "DIAG power_on: vadd regulator enabled\n");

 	ret = regulator_enable(genx320->vddd1);
 	if (ret) {
 		dev_err(dev, "Failed to enable vddd1 regulator: %d\n", ret);
 		goto err_vddd1;
 	}
+	dev_info(dev, "DIAG power_on: vddd1 regulator enabled\n");

 	ret = regulator_enable(genx320->vddd2);
 	if (ret) {
 		dev_err(dev, "Failed to enable vddd2 regulator: %d\n", ret);
 		goto err_vddd2;
 	}
+	dev_info(dev, "DIAG power_on: vddd2 regulator enabled\n");

 	ret = clk_prepare_enable(genx320->inclk);
 	if (ret) {
 		dev_err(dev, "Failed to enable sensor clk: %d\n", ret);
 		goto err_clk;
 	}
+	dev_info(dev, "DIAG power_on: inclk enabled, rate=%lu Hz (want 20000000)\n",
+		 clk_get_rate(genx320->inclk));

-	gpiod_set_value_cansleep(genx320->reset_gpio, 0);
-	msleep(genx320->rstn_delay_ms);
+	if (genx320->reset_gpio) {
+		dev_info(dev, "DIAG power_on: deasserting reset GPIO\n");
+		gpiod_set_value_cansleep(genx320->reset_gpio, 0);
+	} else {
+		dev_info(dev, "DIAG power_on: no reset GPIO (relying on hardware pull-up)\n");
+	}
+	dev_info(dev, "DIAG power_on: waiting %u ms post-reset\n",
+		 genx320->rstn_delay_ms);
+	msleep(genx320->rstn_delay_ms);
+	dev_info(dev, "DIAG power_on: done -- beginning I2C probe\n");

 	return 0;

===========================================================================
HUNK 2 -- genx320_identify_module() / boot-magic check: log before read
===========================================================================
Context: Find the function that contains this exact error line:
    dev_err(dev, "register read ret %d\n", ret);
The line immediately above it is the I2C/regmap read that can return
-121 (-EREMOTEIO).  Add the dev_info BEFORE that read call.

--- a/genx320/genx320.c
+++ b/genx320/genx320.c
@@ genx320_identify_module / genx320_read_boot_magic @@
+	dev_info(dev, "DIAG identify: reading chip-ID register (I2C addr 0x%02x)\n",
+		 client->addr);
 	ret = genx320_read_reg(genx320, GENX320_REG_CHIP_ID, &val);
+	/* -121 = -EREMOTEIO here means the sensor did not ACK on I2C */
 	if (ret) {
 		dev_err(dev, "register read ret %d\n", ret);
 		return ret;
 	}

---------------------------------------------------------------------------
If the driver uses regmap_read instead of genx320_read_reg, the hunk is:

+	dev_info(dev, "DIAG identify: reading chip-ID register (I2C addr 0x%02x)\n",
+		 client->addr);
 	ret = regmap_read(genx320->regmap, GENX320_REG_CHIP_ID, &val);
+	/* -121 = -EREMOTEIO here means the sensor did not ACK on I2C */
 	if (ret) {
 		dev_err(dev, "register read ret %d\n", ret);
 		return ret;
 	}
===========================================================================

After applying, rebuild and reinstall:
  make clean && make psee_sensors
  sudo dkms install psee_sensor_drivers/1.0.1 -k $(uname -r)
  sudo dtoverlay genx320        # or ,cam0
  dmesg | grep DIAG
```

---

## File 4 — `scripts/diagnose_genx320.sh` (new file)

Create this file and make it executable (`chmod +x scripts/diagnose_genx320.sh`).

### What it does

Runs seven checks in sequence and prints a colour-coded hypothesis with
ordered next steps:

1. Is the `genx320` kernel module loaded?
2. Is the DKMS package registered?
3. Is the DT overlay node present in `/proc/device-tree`?
4. Raw dmesg snippet filtered to genx320 / cam_reg / cam_clk / I2C
5. **Power-rail diagnosis** — detects `cam_reg enable` and `-EREMOTEIO` and
   classifies the failure as *no-power* vs *powered-but-silent*
6. I2C bus scan — scans every bus for a device at `0x3c`
7. Media topology — checks whether a `genx320` entity appears in any
   `/dev/media*` device

Run with `sudo ./scripts/diagnose_genx320.sh` or `make diagnose`.

### File content

```bash
#!/bin/bash
# Diagnostic script for GenX320 / CCAM5 bring-up on Raspberry Pi 5.
# Run with sudo for full I2C bus access: sudo ./scripts/diagnose_genx320.sh
#
# Interprets dmesg, I2C bus state, and media topology to distinguish:
#   (a) no-power / no-contact  -> fix FPC / cam_reg
#   (b) powered but no ACK    -> fix clock, reset timing, or sensor damage

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
sep()  { echo ""; echo "------------------------------------------------------------------------"; echo ""; }

echo "==================================================================="
echo " GenX320 / CCAM5 bring-up diagnostic -- $(date)"
echo "==================================================================="

sep
info "1. Kernel module"
if lsmod | grep -qE "^genx320"; then
    ok "genx320 module loaded."
else
    fail "genx320 module NOT loaded."
    echo "   -> Run: sudo modprobe genx320-driver"
    echo "   -> Or verify DKMS with: dkms status"
fi

sep
info "2. DKMS status"
dkms status 2>/dev/null | grep -i "psee\|genx320" || warn "No psee_sensor_drivers DKMS entry found."

sep
info "3. Device-tree overlay"
DT_FOUND=0
if find /proc/device-tree -name "compatible" -exec grep -l "psee,genx320" {} \; 2>/dev/null | grep -q .; then
    DT_FOUND=1
fi
if [ "$DT_FOUND" = "1" ]; then
    ok "genx320 DT node found in device-tree."
else
    fail "genx320 DT node NOT found."
    echo "   -> Load overlay: sudo dtoverlay genx320"
    echo "   -> For cam0 slot: sudo dtoverlay genx320,cam0"
    echo "   -> Persistent (config.txt): camera_auto_detect=0 + dtoverlay=genx320[,cam0]"
fi

sep
info "4. dmesg -- power / clock / reset / I2C (last 60 matching lines)"
echo "--- dmesg snippet ---"
dmesg | grep -iE \
    'genx320|psee|cam[01]_reg|cam[01]_clk|rp1.cfe|regulator.*cam|cam.*regul|inclk|rstn|reset.*cam|cam.*reset|i2c.*3c|3c.*i2c|eremoteio' \
    | tail -60 || true
echo "--- end snippet ---"

sep
info "5. Power-rail state (from dmesg)"
POWER_OK=0; REG_SEEN=0; EREMOTEIO_SEEN=0
dmesg | grep -qiE 'cam[01]_reg.*enabl|enabl.*cam[01]_reg|cam[01]_reg.*on|regulator.*enable.*cam' && REG_SEEN=1
dmesg | grep -q "register read ret -121" && EREMOTEIO_SEEN=1

if [ "$EREMOTEIO_SEEN" = "1" ]; then
    fail "Sensor did not ACK on I2C (register read ret -121 = -EREMOTEIO)."
    if [ "$REG_SEEN" = "1" ]; then
        ok "cam_reg enable seen -> power likely reached the module."
        POWER_OK=1
        warn "Sensor is powered but silent. Likely causes:"
        echo "   (A) 20 MHz inclk not reaching sensor -- verify with oscilloscope on CLK pin."
        echo "   (B) NRST stuck LOW -- check dmesg for 'reset' or 'gpio' messages."
        echo "   (C) rstn-delay-ms too short -- try: dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=800000"
        echo "   (D) Sensor damage from prior overcurrent event."
        echo "   (E) FPC orientation wrong at one end of the Adafruit adapter."
    else
        fail "No cam_reg enable seen in dmesg."
        warn "Power likely NOT reaching the module. Likely causes:"
        echo "   (A) FPC not seated -- inspect both ends (contacts face correct side)."
        echo "   (B) Wrong CSI slot -- overlay loaded for cam1 but cable in cam0 or vice versa."
        echo "   (C) cam_reg stuck off -- try: dtoverlay=genx320,always-on"
        echo "   (D) Pi 5 peripheral-power warning (previous short) -- check dmesg for 'overcurrent'."
    fi
else
    if [ "$REG_SEEN" = "1" ]; then
        ok "cam_reg enable seen, no -EREMOTEIO. Driver may not have probed yet."
    else
        warn "No -EREMOTEIO and no cam_reg message -- driver may not have probed."
        echo "   -> Is the overlay loaded? Run: sudo dtoverlay genx320"
    fi
fi

sep
info "6. I2C bus scan for sensor at 0x3c"
ALL_BUSES=$(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//')
if [ -z "$ALL_BUSES" ]; then
    fail "i2cdetect not found. Run: sudo apt install i2c-tools"
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
        [ "$POWER_OK" = "1" ] && echo "   Power appears OK -- sensor is not responding to I2C at all."
        echo ""
        echo "   Camera I2C buses (likely candidates on Pi 5 -- Synopsys DesignWare):"
        i2cdetect -l 2>/dev/null | grep -i DesignWare || true
    fi
fi

sep
info "7. Media controller topology"
ENTITY_FOUND=0
for d in {0..9}; do
    [ -e "/dev/media${d}" ] || continue
    if media-ctl -p -d "$d" 2>/dev/null | grep -q "genx320"; then
        ok "genx320 entity found in /dev/media${d} -- driver probed successfully!"
        ENTITY_FOUND=1
        media-ctl -p -d "$d" 2>/dev/null
        break
    fi
done
if [ "$ENTITY_FOUND" = "0" ]; then
    fail "genx320 entity not present in any /dev/media* device."
    echo "   This confirms the sensor has not successfully probed."
fi

sep
echo "==================================================================="
echo " Summary"
echo "==================================================================="
[ "$EREMOTEIO_SEEN" = "1" ] && [ "$POWER_OK" = "1" ] && {
    echo " Hypothesis: sensor powered, but clock or reset not arriving."
    echo " Next steps (in order):"
    echo "   1. Scope: confirm 20 MHz on CLK pin of FPC at cam1 header."
    echo "   2. Confirm NRST floats HIGH after power-on (pull-up to module VDD_IO)."
    echo "   3. Try: dtoverlay=genx320,rstn-delay-ms=600,startup-delay-us=900000"
    echo "   4. Check FPC contacts face the correct direction at both adapter ends."
    echo "   5. Enable probe-debug build: make probe-debug, then dmesg | grep DIAG"
}
[ "$EREMOTEIO_SEEN" = "1" ] && [ "$POWER_OK" = "0" ] && {
    echo " Hypothesis: power/contact problem."
    echo " Next steps:"
    echo "   1. Reseat FPC -- contacts must face the correct side at BOTH ends."
    echo "   2. Confirm cam0 vs cam1 slot matches config.txt dtoverlay line."
    echo "   3. Measure 3.3 V on camera connector 3V3 pin when Pi is on."
    echo "   4. Try always-on regulator: dtoverlay=genx320,always-on"
}
[ "$ENTITY_FOUND" = "1" ] && echo " Sensor probed OK. Run ./rp5_setup_v4l.sh next."
echo ""
```

---

## Applying the changes (summary)

```bash
# 1. Clone your fork locally
git clone https://github.com/rubenrosales/rpi-sensor-drivers.git
cd rpi-sensor-drivers
git checkout -b claude/zen-heisenberg-56Ves

# 2. Replace / create the four files above, then:
mkdir -p patches
chmod +x scripts/diagnose_genx320.sh

# 3. Commit
git add overlays/genx320-overlay.dts Makefile \
        patches/0001-genx320-probe-debug-logging.patch \
        scripts/diagnose_genx320.sh
git commit -m "genx320: add assigned-clocks, timing overrides, debug tooling"
git push -u origin claude/zen-heisenberg-56Ves
```

---

## On-Pi workflow after pushing

```bash
# Rebuild overlay + reinstall DKMS module
make all
sudo dkms install psee_sensor_drivers/1.0.1 -k $(uname -r)

# Load overlay (adjust cam0/cam1 to match your cable)
sudo dtoverlay genx320,cam1

# Run the diagnostic
sudo ./scripts/diagnose_genx320.sh

# --- If "powered but silent" ---
# Build with probe-debug logging, reinstall, reload, check dmesg
make probe-debug
sudo dkms install psee_sensor_drivers/1.0.1 -k $(uname -r)
sudo dtoverlay genx320,cam1
dmesg | grep DIAG

# --- If dmesg shows inclk rate = 0 ---
# Clock not programmed -- increase startup delay and try config.txt:
#   camera_auto_detect=0
#   dtoverlay=genx320,cam1,rstn-delay-ms=600,startup-delay-us=900000

# --- If "no power / contact" ---
# Reseat FPC, check cam0/cam1, measure 3.3 V on connector, try always-on:
sudo dtoverlay genx320,cam1,always-on
```
