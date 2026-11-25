# Forwarding performance, measured on a real R8000

Measured 2026-11-24 on a Netgear R8000 (BCM4709A0, 2x Cortex-A9 at
1000 MHz, `clkfreq=1000,800`) running this repository's `default` image
(OpenWrt 25.12-SNAPSHOT, kernel 6.12.118).

## Method

The router had no host on its LAN, so the test is a NAT hairpin
(`tools/perftest/hairpin.sh`): the upstream router runs both iperf3 ends,
the client connects to the R8000's WAN address, a DNAT rule sends the
connection back out of the WAN port to the server, and masquerading brings
the replies back through the R8000. Every data packet is received, looked up,
NATed and transmitted by the R8000 once, as a LAN-to-WAN packet would be, and
nothing terminates on the router, so the CPU numbers below are forwarding
only (`tools/perftest/cpu-usage.sh`, 10 s window in the middle of a 20 s
run). One TCP stream unless noted.

Two things about this board shape every number:

- **One conduit.** WAN and all four LAN ports reach the CPU through switch
  port 8 and one GMAC (`eth2`, 1 Gbit/s). The sum of everything routed in
  both directions shares that one link and its single receive IRQ, so
  routed traffic tops out at ~940 Mbit/s *total*, upload plus download,
  whatever the CPU does. (Port 8 can run at 2 Gbit/s; the fixes for that
  are in Linux 7.4 and in openwrt/openwrt#26789, not in 6.12.)
- **One receive queue.** `eth2` has one RX queue and its IRQ lands on CPU0;
  without packet steering, CPU1 does nothing for forwarding.

## Results

| Flow offloading | eth2 RPS | 1500-byte packets | MSS 300 (~340-byte packets) |
|---|---|---|---|
| off | none (25.12 default, see below) | 481 Mbit/s, CPU0 100 % softirq | 102 Mbit/s |
| off | CPU1 | 521 Mbit/s, CPU1 100 % | 116 Mbit/s |
| off | CPU0+1 | 411 Mbit/s | 89 Mbit/s |
| software | none | 916 Mbit/s, **CPU0 99 % softirq**, CPU1 idle | 210 Mbit/s |
| software | **CPU1 (this build)** | 912 Mbit/s, CPU0 83 % / CPU1 75 % | **296 Mbit/s** |
| software | CPU0+1 | 913 Mbit/s | 170 Mbit/s |
| software + threaded NAPI | none / CPU1 | 903 / 847 Mbit/s | 209 / 191 Mbit/s |

Other runs, software offloading with RPS on CPU1: 4 streams 936 Mbit/s (CPU
~20 % idle); `--bidir` 469 + 460 Mbit/s (wire-limited, see above). GRO on
`eth2` on or off made no difference (it is off by default; `eth2` has no RX
checksum offload). Conntrack showed `[OFFLOAD]` on every software-offloaded
run.

Takeaways:

- Software flow offloading roughly doubles routed throughput (481 -> 916
  Mbit/s, 102 -> 210 Mbit/s at small packets). Keep it on (it is, by
  `overlays/common/etc/uci-defaults/10-flow-offloading`).
- With it on, full-size traffic already hits the gigabit wire, but CPU0 is
  saturated doing it. Steering `eth2`'s receive processing to CPU1 leaves
  ~20 % of both CPUs free at line rate and is +41 % at small packets.
- RPS onto both CPUs is *worse* than none: a flow that hashes to CPU0 pays
  the RPS cost on the CPU that already takes the IRQ. Threaded NAPI is worse
  too.

## The packet-steering bug this build fixes

OpenWrt 25.12's `bcm53xx` `/usr/libexec/platform/packet-steering.sh`
hard-codes `eth0` as the switch conduit. On the R8000 the conduit is `eth2`,
so `packet_steering=1` (the default here) set RPS on an unused interface and
left `eth2` at 0 - the "none" rows above. `overlays/common/usr/libexec/platform/packet-steering.sh`
replaces it with a version that finds the conduit the user ports hang off
(the same logic openwrt/openwrt#26789 adds upstream) and steers it to CPU1
with software offloading, none with hardware offloading.

## Wi-Fi

`brcmfmac` (FullMAC, BCM43602) has no flowtable/WED-style hook
(`ndo_setup_tc`/`ndo_fill_forward_path`): Wi-Fi traffic always crosses PCIe
to the CPU and is forwarded in software (the software flowtable still
applies). Broadcom's "Runner"/"Archer" offloads belong to the BCA (BCM63xx/
4908) line and do not exist on Northstar. Not measured here: no Wi-Fi client
was available at the router.
