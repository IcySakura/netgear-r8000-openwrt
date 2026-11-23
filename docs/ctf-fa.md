# Hardware packet offload (CTF/FA): investigated, not included

Short version: **this build does not include Broadcom's Flow Accelerator
(FA)/Cut-Through Forwarding (CTF) offload.** This is a deliberate decision
after reading the actual pull request, not an oversight - here is why.

## What exists upstream

[openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789),
"bcm53xx: offload flows to the Northstar flow accelerator", opened
2026-11-18 by egc112 with a substantial series from strrs, targets `main`
(not any release branch). It is a clean-room **reimplementation**, not a
proprietary blob: a new in-tree driver (`drivers/net/ethernet/broadcom/bgmac-fa.c`)
that reimplements Broadcom's Northstar FA register/table sequences from
Broadcom's own GPL-released `et` reference driver (`etc_fa.c`, ISC-licensed),
modelled stylistically on the existing in-kernel `mtk_ppe_offload.c`. No
firmware blob is loaded and no binary data appears in the diff. It wires
nftables' hardware flowtable offload into that silicon block sitting between
GMAC2 and switch port 8, for IPv4 NAT/routing, routed IPv6, and flows over
802.1Q VLANs.

The author's own numbers (their words): **"TCP from LAN to WAN 941 Mbit/s up
and down with the CPU 97% idle, flows in hardware,"** tested on a **Linksys
EA6900** (BCM4708) and separately confirmed by another contributor on an
**Asus RT-N18U** (BCM53011). These are the PR author's own, self-reported
measurements - not independently reproduced by OpenWrt's project, not peer
benchmarked, and not measured on an R8000.

## Why it is not in this build

1. **It does not touch the R8000 at all.** Searching the full diff for
   "r8000" or "R8000" returns nothing. The R8000 is a BCM4709-family device
   like the R7000/R7900, and those two *are* touched by the series' generic
   CPU-port DTS patch (`376-...use-IMP0-port-8-as-the-CPU-port.patch`,
   31 files) - but `bcm4709-netgear-r8000.dts` is conspicuously **absent**
   from that file list, and no R8000-specific FA-tag/trap-port DTS patch
   exists anywhere in the series, unlike the EA6900 and RT-N18U which each
   get one. Nobody has written R8000 enablement for this driver.
2. **It targets `main`, not a release branch**, and is unmerged with **1 of
   the 6 approving reviews OpenWrt requires**. Two reviewers (independently)
   flagged that Broadcom's own engineer, Florian Fainelli, already has a
   mainline FA driver in progress upstream in the Linux kernel itself, and
   suggested rebasing on or waiting for that instead - sentiment the PR's own
   author agrees with, calling it "the right long-term home" and saying
   OpenWrt should switch once it lands. This PR is explicitly a stopgap by
   its own author's description.
3. **Including it would mean writing new, untested code**, not cherry-picking
   an existing, validated one. The core driver (`bgmac-fa.c`, the `tag_brcm`
   DSA opcode handling, the b53 trap-port patches) is SoC-family-generic
   enough that extending it to the R8000 is *plausible* - but doing so means
   this repository's maintainer would have to write the R8000 DTS enablement
   patches the PR's author never wrote, with no way to validate them against
   real R8000 hardware before shipping, on top of code that is itself still
   under review and may yet change before merging (or never merge).

Given this repository cannot flash or test on real hardware (see the
README), shipping untested, self-written DTS enablement for unreviewed,
unmerged driver code - on top of unverified performance claims measured on
different hardware - is a materially different (and much higher) risk than
cherry-picking a patch that already targets this exact board, like the two
patches this repository *does* carry (see `patches/0001` and `patches/0002`).
That is a bar this does not clear.

## What this means for throughput

Without FA, wired routing/NAT on this platform runs through the normal Linux
networking stack plus the generic software flowtable fastpath (`flow_offloading`,
turned on by default - see the README's "Hardware acceleration" section and
`overlays/common/etc/uci-defaults/10-flow-offloading`). Community reports on
other bcm53xx devices (a Phicomm K3, with Broadcom's older CTF rather than
FA) have reached close to wire speed on a single gigabit link; this build's
baseline should be in a similar range, but that has not been measured on an
R8000 running this image.

## If you want to pursue this yourself

- Watch [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789)
  and Florian Fainelli's mainline FA work; either landing would be a far
  better foundation than extending an unmerged third-party PR by hand.
- If you do want to experiment now: the missing piece is R8000-specific DTS
  wiring (an FA tag and trap-port definition analogous to what the EA6900 and
  RT-N18U got in that PR) added to `bcm4709-netgear-r8000.dts`, plus the
  series' driver/DSA/b53 patches. Expect to need real hardware to validate
  it - a wrong trap-port/tag definition on a live switch is not something to
  find out from a changelog.
