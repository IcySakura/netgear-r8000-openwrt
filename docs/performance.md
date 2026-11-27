# Forwarding Performance (`main` / kernel 6.12)

Tested on the Netgear R8000 (BCM4709A0 @ 1 GHz, OpenWrt 25.12 / kernel 6.12) using a single-stream NAT hairpin test (`tools/perftest/`).

## Results

| Flow offloading | `eth2` RPS | 1500B packets | MSS 300 (~340B packets) |
|---|---|---|---|
| off | none (25.12 default) | 481 Mbit/s, CPU0 100% softirq | 102 Mbit/s |
| off | CPU1 | 521 Mbit/s, CPU1 100% | 116 Mbit/s |
| software | none | 916 Mbit/s, CPU0 99% softirq, CPU1 idle | 210 Mbit/s |
| software | **CPU1 (this build)** | **912 Mbit/s**, CPU0 83% / CPU1 75% | **296 Mbit/s** |
| software | CPU0+1 | 913 Mbit/s | 170 Mbit/s |

- **Multi-stream / bidir (software offload + CPU1 RPS):** 4 streams reach 936 Mbit/s (~20% CPU idle); bidirectional reaches 469 + 460 Mbit/s (shared 1 Gbit/s CPU conduit on kernel 6.12).
- **Hardware offload:** For 2 Gbps IMP0 port 8 and Broadcom Northstar Flow Accelerator offload (~940 Mbit/s @ ~100% CPU idle, 742 Mbit/s @ MSS 300), see the `experimental/bcm53xx-hw-offload` branch ([docs/ctf-fa.md](ctf-fa.md)).

## Packet-steering fix

OpenWrt 25.12's `bcm53xx` `/usr/libexec/platform/packet-steering.sh` hard-codes `eth0` as the switch conduit, while the R8000 uses `eth2`. `overlays/common/usr/libexec/platform/packet-steering.sh` detects the active DSA conduit (`eth2`) and steers its RPS to CPU1 when using software offloading (leaving CPU0 for IRQs), improving small-packet throughput by +41% and freeing ~20% CPU at line rate.
