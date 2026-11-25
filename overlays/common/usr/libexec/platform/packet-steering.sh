#!/bin/sh
# Replaces OpenWrt 25.12's bcm53xx /usr/libexec/platform/packet-steering.sh,
# which hard-codes eth0 as the switch conduit. On the Netgear R8000 the only
# conduit in use is eth2 (gmac2, switch port 8), so with packet_steering=1
# the stock script set RPS on an unused interface and left eth2 at 0: one CPU
# did all the forwarding while the other idled. This version finds the
# conduit the user ports hang off (same logic as "bcm53xx: find the DSA
# conduit in packet-steering.sh" in openwrt/openwrt#26789) and steers its
# receive processing to CPU1, away from CPU0, which takes the eth2 IRQ.
#
# Measured on an R8000 (docs/performance.md): software flow offloading,
# one TCP stream at MSS 300: 210 -> 296 Mbit/s; full-size: 916 Mbit/s with
# CPU0 at 99% softirq -> 912 Mbit/s with ~20% of both CPUs idle.
# RPS onto both CPUs (mask 3) was worse than none - flows hashed to CPU0
# pay the RPS cost on the busy CPU - and threaded NAPI was worse still.

packet_steering="$(uci -q get network.@globals[0].packet_steering)"
flow_offloading="$(uci -q get firewall.@defaults[0].flow_offloading)"
flow_offloading_hw="$(uci -q get firewall.@defaults[0].flow_offloading_hw)"

# The conduit with the most interfaces linked to it (the user ports' one)
conduit=eth2
users=0
for d in /sys/class/net/*/dsa; do
	[ -d "$d" ] || continue
	dev="${d%/dsa}"
	dev="${dev##*/}"
	ifindex="$(cat /sys/class/net/$dev/ifindex)"
	n=0
	for l in /sys/class/net/*/iflink; do
		[ "${l%/iflink}" = "/sys/class/net/$dev" ] && continue
		[ "$(cat "$l")" = "$ifindex" ] && n=$((n + 1))
	done
	[ $n -gt $users ] && conduit="$dev" users=$n
done

rps() { [ -e "/sys/class/net/$1/queues/rx-0/rps_cpus" ] && echo "$2" > "/sys/class/net/$1/queues/rx-0/rps_cpus"; }

if [ "$packet_steering" != 1 ]; then
	rps br-lan 0
	rps "$conduit" 0
elif [ "${flow_offloading_hw:-0}" -gt 0 ]; then
	rps br-lan 0
	rps "$conduit" 0
elif [ "${flow_offloading:-0}" -gt 0 ]; then
	rps br-lan 0
	rps "$conduit" 2
else
	rps br-lan 2
	rps "$conduit" 0
fi
exit 0
