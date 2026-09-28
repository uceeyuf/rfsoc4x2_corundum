#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2026 Yijie Yu
#
# Measure receive performance on the board while the peer sends (pktgen, iperf3 ...).
# Usage: rx_measure.sh [iface] [seconds]      e.g.  rx_measure.sh eth0 10
# Prints rate, packet rate, drops, per-CPU load and softirq share, mqnic IRQ rates,
# softnet drops/squeezes, and the IRQ affinity in effect, so A/B runs can be compared.

IF=${1:-eth0}
T=${2:-10}
S=/sys/class/net/$IF/statistics
[ -d "$S" ] || { echo "no interface $IF" >&2; exit 1; }

ctr() { cat "$S/$1" 2>/dev/null || echo 0; }
snap_ctr() { for c in rx_packets rx_bytes rx_dropped rx_missed_errors rx_fifo_errors rx_over_errors; do echo "$c $(ctr $c)"; done; }
snap_irq() { grep -i mqnic /proc/interrupts; }

echo "kernel $(uname -r)  iface $IF  mtu $(cat /sys/class/net/$IF/mtu)  window ${T}s"
echo "IRQ affinity:"
for irq in $(grep -i mqnic /proc/interrupts | awk -F: '{print $1}'); do
    printf "  irq %s (%s) -> cpu %s\n" "$irq" "$(grep "^ *$irq:" /proc/interrupts | awk '{print $NF}')" "$(cat /proc/irq/$irq/smp_affinity_list)"
done

C0=$(snap_ctr); P0=$(grep '^cpu[0-9]' /proc/stat); I0=$(snap_irq); N0=$(cat /proc/net/softnet_stat)
sleep "$T"
C1=$(snap_ctr); P1=$(grep '^cpu[0-9]' /proc/stat); I1=$(snap_irq); N1=$(cat /proc/net/softnet_stat)

echo
paste <(echo "$C0") <(echo "$C1") | awk -v T="$T" '
    { d[$1] = $4 - $2 }
    END {
        printf "rx     %.2f Gbit/s  %.3f Mpps  (rx_bytes, no FCS/preamble)\n", d["rx_bytes"]*8/T/1e9, d["rx_packets"]/T/1e6
        printf "drops  rx_dropped %d  rx_missed %d  rx_fifo %d  rx_over %d\n", d["rx_dropped"], d["rx_missed_errors"], d["rx_fifo_errors"], d["rx_over_errors"]
    }'

echo "per-CPU load (busy% / softirq% / irq%):"
paste <(echo "$P0") <(echo "$P1") | awk '{
    n = (NF / 2); t0 = 0; t1 = 0
    for (i = 2; i <= n; i++) t0 += $i
    for (i = n + 2; i <= NF; i++) t1 += $i
    dt = t1 - t0; if (dt <= 0) dt = 1
    idle = ($(n+5) + $(n+6)) - ($5 + $6)
    printf "  %-5s busy %5.1f%%  softirq %5.1f%%  irq %5.1f%%\n", $1, 100*(dt-idle)/dt, 100*($(n+8)-$8)/dt, 100*($(n+7)-$7)/dt
}'

echo "mqnic IRQ rate (per second, per CPU column):"
paste -d'|' <(echo "$I0") <(echo "$I1") | awk -F'|' -v T="$T" '{
    na = split($1, a, " "); split($2, b, " "); line = sprintf("  irq %-4s", a[1])
    for (i = 2; i <= na && a[i] ~ /^[0-9]+$/; i++) line = line sprintf(" %8.0f", (b[i]-a[i])/T)
    print line "  " a[na]
}'

echo "softnet (per CPU): processed / dropped / time_squeeze in window"
paste <(echo "$N0") <(echo "$N1") | awk '
    function hex(s,   i, v, c) { v = 0; s = tolower(s)
        for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c }
        return v }
    { n = NF / 2
      printf "  cpu%-2d %10d %8d %8d\n", NR-1, hex($(n+1))-hex($1), hex($(n+2))-hex($2), hex($(n+3))-hex($3) }'
