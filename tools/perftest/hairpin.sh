#!/bin/bash
# Forwarding benchmark for a router with no host behind it: a "hairpin"
# through its NAT. A host on the router's WAN side (here the upstream router,
# HOST) runs both iperf3 ends: the client connects to the R8000's WAN address,
# a DNAT rule on the R8000 sends it back out of the WAN port to the server on
# HOST, and masquerading makes the replies come back through the R8000. Every
# data packet is received, NATed (twice) and transmitted by the R8000 exactly
# once, as a LAN->WAN flow would be; nothing terminates on the R8000, so its
# CPU numbers are forwarding cost only. The wire caps the sum of both
# directions at ~940 Mbit/s (each direction crosses the WAN cable twice).
#
# Setup on the R8000 (remove afterwards):
#   uci add firewall redirect; uci set firewall.@redirect[-1].name=tmp_perftest
#   uci set firewall.@redirect[-1].src=wan; uci set firewall.@redirect[-1].dest=wan
#   uci set firewall.@redirect[-1].proto='tcp udp'; uci set firewall.@redirect[-1].src_dport=5299
#   uci set firewall.@redirect[-1].dest_ip=<HOST LAN IP>; uci set firewall.@redirect[-1].dest_port=5299
#   uci set firewall.@redirect[-1].target=DNAT; uci commit firewall; fw4 reload
# and copy tools/perftest/cpu-usage.sh to /tmp/cpu-usage.sh on it.
#
# usage: hairpin.sh LABEL [iperf3 client args...]   e.g. hairpin.sh sw -M 300
# env:   R8 (ssh target of the R8000), HOST (ssh target of the iperf3 host),
#        HOST_IP (its address on the R8000's WAN side), R8_WAN (R8000 WAN IP)
L=$1; shift
R8=${R8:-"-p 8000 vanke-old-router-via-r76s"}
HOST=${HOST:-vanke-router}
HOST_IP=${HOST_IP:-192.168.21.1}
R8_WAN=${R8_WAN:-192.168.21.10}
T=${T:-20}
( sleep 6; ssh $R8 "/tmp/cpu-usage.sh 10; grep -E 'dport=5299' /proc/net/nf_conntrack | grep -oE '\[(OFFLOAD|HW_OFFLOAD|ASSURED)\]' | sort | uniq -c" > "mon-$L.txt" 2>&1 ) &
ssh "$HOST" "timeout $((T + 20)) iperf3 -s -1 -B $HOST_IP -p 5299 >/dev/null 2>&1 & sleep 1; timeout $((T + 20)) iperf3 -c $R8_WAN -p 5299 -t $T $* 2>&1 | tail -8" > "ip-$L.txt" 2>&1
wait
echo "== $L"; grep -E "sender|receiver" "ip-$L.txt"; cat "mon-$L.txt"
