#!/bin/sh
# Run as root on the sending side (board or host):
#   pktgen.sh <dev> <dst_mac> <dst_ip> <src_ip> [threads] [pkt_size] [count_per_thread] [ports_per_thread]
# One kernel pktgen thread per TX queue, UDP to port 9. pkt_size excludes the FCS.
# Each thread cycles through ports_per_thread UDP source ports (one flow each). The
# receiver's RSS spreads flows over its queues: 4 flows land on only 2 of the board's
# 4 RX queues, 4 threads x 64 ports reach all 4.
DEV=${1:?dev}; DMAC=${2:?dst_mac}; DIP=${3:?dst_ip}; SIP=${4:?src_ip}
T=${5:-4}; SZ=${6:-1514}; N=${7:-3000000}; P=${8:-1}
PG=/proc/net/pktgen

pgset() { echo "$2" > "$1" || echo "pktgen rejected: $1 <- $2" >&2; }

modprobe pktgen 2>/dev/null
pgset $PG/pgctrl reset
i=0
while [ $i -lt $T ]; do
    pgset $PG/kpktgend_$i rem_device_all
    pgset $PG/kpktgend_$i "add_device $DEV@$i"
    D=$PG/$DEV@$i
    for c in "count $N" "clone_skb 1000" "pkt_size $SZ" "delay 0" "burst 32" \
             "queue_map_min $i" "queue_map_max $i" "dst_mac $DMAC" "dst $DIP" \
             "src_min $SIP" "src_max $SIP" "udp_src_min $((9000 + i * P))" \
             "udp_src_max $((9000 + i * P + P - 1))" "udp_dst_min 9" "udp_dst_max 9"; do
        pgset $D "$c"
    done
    i=$((i + 1))
done

# Blocks until every thread has sent its count.
pgset $PG/pgctrl start

i=0
while [ $i -lt $T ]; do
    echo "q$i: $(grep -A1 Result $PG/$DEV@$i | tr -s ' \n' ' ')"
    i=$((i + 1))
done
pgset $PG/pgctrl reset
