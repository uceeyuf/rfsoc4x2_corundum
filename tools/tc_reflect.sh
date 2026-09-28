#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2026 Yijie Yu
#
# Reflect UDP packets back to the sender inside the kernel (tc ingress), with no socket
# and no copy. Needs a kernel with CONFIG_NET_SCHED, sch_ingress, cls_flower, act_pedit
# and act_mirred. Run as root on the board:
#   tc_reflect.sh <host_mac> <host_ip> [base_port] [ports] [dev]    (default 1234 16 eth0)
#   tc_reflect.sh off [dev]
# Only the MAC and IP addresses are swapped; the IP and UDP checksums do not change when
# source and destination swap, and the ports stay as they are, so the sender must use
# local port = remote port (host/udp_loopback_viewer.py does).
set -e
if [ "$1" = off ]; then
    tc qdisc del dev "${2:-eth0}" ingress 2>/dev/null || true
    echo "reflector off"
    exit 0
fi
HMAC=${1:?host_mac}
HIP=${2:?host_ip}
BASE=${3:-1234}
N=${4:-16}
DEV=${5:-eth0}
BMAC=$(cat /sys/class/net/$DEV/address)
BIP=$(ip -4 -o addr show dev "$DEV" | awk '{print $4}' | cut -d/ -f1 | head -1)

for m in sch_ingress cls_flower act_pedit act_mirred; do modprobe $m; done
tc qdisc del dev "$DEV" ingress 2>/dev/null || true
tc qdisc add dev "$DEV" ingress
tc filter add dev "$DEV" parent ffff: protocol ip prio 1 flower \
    ip_proto udp src_ip "$HIP" dst_ip "$BIP" dst_port "$BASE-$((BASE + N - 1))" \
    action pedit ex munge eth dst set "$HMAC" munge eth src set "$BMAC" \
                    munge ip src set "$BIP" munge ip dst set "$HIP" pipe \
    action mirred egress redirect dev "$DEV"
echo "reflecting UDP $HIP -> $BIP:$BASE-$((BASE + N - 1)) on $DEV"
tc -s filter show dev "$DEV" parent ffff:
