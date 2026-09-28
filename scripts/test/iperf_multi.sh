#!/bin/sh
# Run on the board: iperf_multi.sh <server_ip> [extra iperf3 args, e.g. -R]
# Four iperf3 clients, one pinned to each CPU, to ports 5201-5204. iperf3 3.9 is
# single-threaded, so -P alone keeps every stream on one core.
# Server side: for p in 5201 5202 5203 5204; do iperf3 -s -p $p & done
SERVER=${1:?server_ip}; shift
i=0
for p in 5201 5202 5203 5204; do
    taskset -c $i iperf3 -c $SERVER -p $p -t 10 "$@" > /tmp/iperf_$p.log 2>&1 &
    i=$((i + 1))
done
wait
for p in 5201 5202 5203 5204; do
    echo "port $p: $(grep -E 'receiver$' /tmp/iperf_$p.log | tr -s ' ')"
done
grep -hE 'receiver$' /tmp/iperf_520?.log | awk '{
    v = $7; if ($8 ~ /^M/) v /= 1000; s += v
} END { printf "total (receiver): %.2f Gbits/sec\n", s }'
