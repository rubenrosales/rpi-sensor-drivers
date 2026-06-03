
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
		|| (echo "WARNING: patch did not apply cleanly — see .rej files in drivers/." \
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