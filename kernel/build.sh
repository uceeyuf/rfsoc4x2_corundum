#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2026 Yijie Yu
#
# Cross-compile the board's kernel with BPF and tc (needed by tools/tc_reflect.sh), plus
# mqnic.ko for it, on an x86 Linux host. Same source as PetaLinux 2020.2 (linux-xlnx tag
# xilinx-v2020.2), the board's own configuration, and bpf_tc.cfg on top.
#
#   kernel/build.sh <board.config> [corundum_dir]
#     board.config  zcat /proc/config.gz from the running board
#     corundum_dir  Corundum at 1ca0151 (default: the third_party/corundum submodule)
#   KBUILD_WORK=<dir> puts the 1-2 GB of sources and objects there instead of kernel/work.
# Needs gcc-9-aarch64-linux-gnu flex bison bc libssl-dev curl.
# Writes kernel/out/Image.bpf and kernel/out/modules-bpf.tar.gz (/lib/modules/<release>).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
CFG=$(readlink -f "${1:?board.config}")
CORUNDUM=$(readlink -f "${2:-$REPO/third_party/corundum}")
TAG=xilinx-v2020.2
W=${KBUILD_WORK:-$HERE/work}
OUT=$HERE/out
K=$W/linux-xlnx-$TAG
# HOSTCFLAGS=-fcommon: the 5.4 dtc does not build with the default -fno-common of gcc >= 10
MK=(make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc-9 HOSTCFLAGS=-fcommon)

[ -f "$CORUNDUM/modules/mqnic/mqnic_rx.c" ] || { echo "no Corundum sources at $CORUNDUM (git submodule update --init)"; exit 1; }
mkdir -p "$W" "$OUT"
[ -d "$K" ] || curl -sSL "https://github.com/Xilinx/linux-xlnx/archive/refs/tags/$TAG.tar.gz" | tar -xz -C "$W"

cd "$K"
cp "$CFG" .config
ARCH=arm64 scripts/kconfig/merge_config.sh -m .config "$HERE/bpf_tc.cfg" > /dev/null
"${MK[@]}" olddefconfig > /dev/null
for opt in $(sed 's/=.*//' "$HERE/bpf_tc.cfg"); do
    grep -q "^$opt=" .config || { echo "$opt did not stick in .config"; exit 1; }
done
"${MK[@]}" -j"$(nproc)" Image modules
rm -rf "$W/stage"
"${MK[@]}" INSTALL_MOD_PATH="$W/stage" INSTALL_MOD_STRIP=1 modules_install > /dev/null
REL=$(cat include/config/kernel.release)

# mqnic.ko: Corundum's driver with patches/0001 (RX sync fix) and 0002 (5.4 build fix)
rm -rf "$W/mqnic"
cp -r "$CORUNDUM/modules/mqnic" "$W/mqnic"
for p in "$REPO"/patches/*.patch; do
    patch -s -d "$W/mqnic" -p3 < "$p"
done
"${MK[@]}" -C "$K" M="$W/mqnic" -j"$(nproc)" modules
mkdir -p "$W/stage/lib/modules/$REL/extra"
aarch64-linux-gnu-strip --strip-debug -o "$W/stage/lib/modules/$REL/extra/mqnic.ko" "$W/mqnic/mqnic.ko"
rm -f "$W/stage/lib/modules/$REL/build" "$W/stage/lib/modules/$REL/source"

cp arch/arm64/boot/Image "$OUT/Image.bpf"
tar -C "$W/stage/lib/modules" -czf "$OUT/modules-bpf.tar.gz" "$REL"
(cd "$OUT" && md5sum Image.bpf modules-bpf.tar.gz > md5.txt)
echo "kernel $REL: $OUT/Image.bpf, $OUT/modules-bpf.tar.gz"
