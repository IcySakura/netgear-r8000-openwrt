# Hardware Packet Offload (Northstar Flow Accelerator)

## `main` branch (`openwrt-25.12`, kernel 6.12)

Official OpenWrt `25.12` does not include a hardware NAT/flow-offload driver for BCM4709A0. On `main`, forwarding uses Linux **software flow offloading** (`flow_offloading=1`) combined with `eth2` RPS packet steering onto CPU1.

## `experimental/bcm53xx-hw-offload` branch (kernel 6.18)

Upstream pull request [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789) implements a clean-room driver (`bgmac-fa`) for Broadcom's Northstar Flow Accelerator (GMAC3 + BCM53012 switch port 8 IMP0 at 2 Gbps + port 5 trap port).

The R8000's BCM4709A0 + BCM53012 rev 5 silicon includes the Flow Accelerator hardware (`GMAC3` core) and already uses port 8 (`eth2`) as its CPU port. The `experimental/bcm53xx-hw-offload` branch builds on that PR with a small R8000 devicetree patch (`patches/0003`) to enable port 5 as the trap port, plus `patches/0004` to fix kernel 6.18's 3rd-radio PCIe BAR allocation.

See [docs/experimental-hw-offload-branch.md](experimental-hw-offload-branch.md) for tested throughput numbers and details. Once the Flow Accelerator driver lands in official OpenWrt, the experimental branch can be retired.
