# `experimental/bcm53xx-hw-offload` Branch

This branch enables Broadcom Northstar Hardware Flow Accelerator (`bgmac-fa`) offload on the Netgear R8000 on top of [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789).

## Differences from `main`

| | `main` | `experimental/bcm53xx-hw-offload` |
|---|---|---|
| Upstream base | Official `openwrt-25.12` | `egc112/openwrt` (`bcm53xx-fa` PR branch) |
| Kernel | 6.12 | 6.18 |
| Offload | Software flow offloading + `eth2` RPS | Hardware Flow Accelerator (`bgmac-fa`) + 2 Gbps IMP0 port 8 |
| Extra patches | `0001`, `0002` | `0001`, `0002`, `0003` (port 5 trap port), `0004` (3rd-radio PCIe BAR fix) |
| Automation | Daily scheduled builds | Manual `workflow_dispatch` or local build only |

## Tested results

- **Hardware offload (`[HW_OFFLOAD]`):**
  - 1500B routed TCP: **940 Mbit/s**, 0 retransmits, **99.8% CPU idle**
  - 1500B SNAT/NAT TCP: **941 Mbit/s**, 0 retransmits, **100.0% CPU idle**
  - MSS 300 (~340B) routed TCP: **742 Mbit/s (~393k pps)**, **99.9% CPU idle** (vs 296 Mbit/s @ ~80% CPU with software offload)
  - Double-NAT hairpins (`snat && dnat` on the same flow) fall back to software flowtable offload (`[OFFLOAD]`), as the hardware has one NAT slot per flow.
- **All 3 BCM43602 radios (`patches/0004`):** Fixes kernel 6.18 `pbus_size_mem()` alignment overflow on the PLX PEX8603 switch (`0001:01:00.0`) so `0001:04:00.0` (second 5 GHz radio) allocates its BARs cleanly.
- **Wi-Fi IRQ balancing (`overlays/common/etc/init.d/r8000-wifi-irq`):** Pins `pcie0` (5 GHz High) to CPU0 and `pcie1` (2.4 GHz + 5 GHz Low) to CPU1.

## Enabling Hardware Offload

In `/etc/config/firewall` (or LuCI *Network > Firewall*):
```sh
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall
reboot
```

A preinit hook (`99_20_flow_accel`) switches `eth0` and `eth2` to `brcm-prepend` only when both flags are enabled. For a one-shot test, `touch /etc/fa-trial` before rebooting so `99_30_fa_trial` clears `flow_offloading_hw` after applying it once.

## Building

```sh
scripts/build.sh --profile default
```

Keep NMRP or serial recovery ready when switching between `main` (kernel 6.12) and this branch (kernel 6.18).
