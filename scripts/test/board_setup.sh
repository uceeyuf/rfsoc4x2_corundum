#!/bin/sh
# Run as root on the board: board_setup.sh [address/prefix] [mtu]
set -e
ADDR=${1:-192.168.100.1/24}
MTU=${2:-1500}
DEV=eth0

ip addr flush dev $DEV
ip addr add $ADDR dev $DEV
ip link set $DEV mtu $MTU up

# All mqnic interrupts land on CPU0 by default, which caps TX at about 1.25 Mpps.
i=0
n=$(nproc)
for irq in $(awk '/mqnic0-/ {sub(":", "", $1); print $1}' /proc/interrupts); do
    printf "%x" $((1 << (i % n))) > /proc/irq/$irq/smp_affinity
    i=$((i + 1))
done

grep mqnic0- /proc/interrupts
ip -br addr show $DEV
