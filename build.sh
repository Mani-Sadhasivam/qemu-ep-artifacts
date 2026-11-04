#!/bin/bash
#
# Build the guest kernel and root filesystem used by the QEMU functional test
# tests/functional/aarch64/test_pcie_ep.py.
#
# The test boots a single aarch64 guest that drives both ends of an emulated
# PCIe link. That needs a kernel with the out-of-tree Endpoint Controller
# driver for QEMU's pcie-ep-ctrl device, and a root filesystem carrying the
# pci_endpoint kernel selftest. Neither is available from a distribution, so
# this script builds both from pinned sources.
#
# Output: out/pcie-ep-stack.tar.xz containing
#
#   pcie-ep-stack/Image            arm64 kernel
#   pcie-ep-stack/rootfs.cpio.gz   busybox initramfs with pci_endpoint_test
#
# Requirements: an aarch64 cross toolchain (CROSS_COMPILE, default
# aarch64-linux-gnu-), git, curl, cpio, bc, flex, bison, libssl-dev and xz.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

# Linux 7.1-rc4 plus the Endpoint Controller driver for pcie-ep-ctrl.
LINUX_URL=https://github.com/Mani-Sadhasivam/linux.git
LINUX_COMMIT=ed07242cb2e87bb3f72500949f3449febcec6210

BUSYBOX_VERSION=1.37.0
BUSYBOX_URL=https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2
BUSYBOX_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4

CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

TOP=$(cd "$(dirname "$0")" && pwd)
SRC=$TOP/src
OUT=$TOP/out
ROOTFS=$TOP/rootfs

export ARCH=arm64
export CROSS_COMPILE

mkdir -p "$SRC" "$OUT"

echo "=== fetching Linux $LINUX_COMMIT"
if [ ! -d "$SRC/linux/.git" ]; then
	mkdir -p "$SRC/linux"
	git -C "$SRC/linux" init -q
	git -C "$SRC/linux" remote add origin "$LINUX_URL"
fi
git -C "$SRC/linux" fetch -q --depth 1 origin "$LINUX_COMMIT"
git -C "$SRC/linux" checkout -q FETCH_HEAD

echo "=== configuring kernel"
make -C "$SRC/linux" defconfig
# The Endpoint framework, the generic Endpoint Controller driver for
# pcie-ep-ctrl, the test Function and the host side test driver. All built in,
# because the initramfs carries no modules. pciehp is needed too: starting the
# link makes the controller hotplug the Function onto a Root Port, and without
# it the host side of the same kernel never enumerates the Function.
"$SRC"/linux/scripts/config --file "$SRC/linux/.config" \
	--enable PCI_ENDPOINT \
	--enable PCI_ENDPOINT_CONFIGFS \
	--enable PCI_EP_GENERIC \
	--enable PCI_EPF_TEST \
	--enable PCI_ENDPOINT_TEST \
	--enable HOTPLUG_PCI \
	--enable HOTPLUG_PCI_PCIE
make -C "$SRC/linux" olddefconfig

echo "=== building kernel"
make -C "$SRC/linux" -j"$JOBS" Image

echo "=== building pci_endpoint_test selftest"
# Built statically and by hand rather than through the selftest Makefile, so
# that the result is a single binary with no runtime dependencies.
(cd "$SRC/linux/tools/testing/selftests/pci_endpoint" &&
 "${CROSS_COMPILE}gcc" -static -O2 -Wall -I.. \
	pci_endpoint_test.c -o "$OUT/pci_endpoint_test")

echo "=== fetching busybox $BUSYBOX_VERSION"
BUSYBOX_TAR=$SRC/busybox-$BUSYBOX_VERSION.tar.bz2
[ -f "$BUSYBOX_TAR" ] || curl -fsSL -o "$BUSYBOX_TAR" "$BUSYBOX_URL"
echo "$BUSYBOX_SHA256  $BUSYBOX_TAR" | sha256sum -c -

echo "=== building busybox"
BUSYBOX_SRC=$SRC/busybox-$BUSYBOX_VERSION
[ -d "$BUSYBOX_SRC" ] || tar -C "$SRC" -xf "$BUSYBOX_TAR"
make -C "$BUSYBOX_SRC" defconfig
# A static binary so the initramfs needs no libc. The traffic control applet
# does not build against current kernel headers, and the SHA hardware
# acceleration in the busybox defconfig is x86 only.
sed -i \
	-e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' \
	-e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' \
	-e 's/^CONFIG_SHA1_HWACCEL=y$/# CONFIG_SHA1_HWACCEL is not set/' \
	-e 's/^CONFIG_SHA256_HWACCEL=y$/# CONFIG_SHA256_HWACCEL is not set/' \
	"$BUSYBOX_SRC/.config"
make -C "$BUSYBOX_SRC" oldconfig </dev/null >/dev/null
make -C "$BUSYBOX_SRC" -j"$JOBS"

echo "=== assembling initramfs"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,dev,proc,sys,tmp}
install -m 0755 "$BUSYBOX_SRC/busybox" "$ROOTFS/bin/busybox"
install -m 0755 "$OUT/pci_endpoint_test" "$ROOTFS/bin/pci_endpoint_test"
install -m 0755 "$TOP/init" "$ROOTFS/init"
(cd "$ROOTFS" && find . | cpio -o -H newc --quiet | gzip -9) \
	> "$OUT/rootfs.cpio.gz"

echo "=== packing out/pcie-ep-stack.tar.xz"
rm -rf "$OUT/pcie-ep-stack"
mkdir -p "$OUT/pcie-ep-stack"
cp "$SRC/linux/arch/arm64/boot/Image" "$OUT/pcie-ep-stack/Image"
cp "$OUT/rootfs.cpio.gz" "$OUT/pcie-ep-stack/rootfs.cpio.gz"
tar -C "$OUT" -cJf "$OUT/pcie-ep-stack.tar.xz" pcie-ep-stack

echo
echo "built $OUT/pcie-ep-stack.tar.xz"
sha256sum "$OUT/pcie-ep-stack.tar.xz"
