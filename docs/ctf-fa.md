# Hardware packet offload (CTF/FA): investigated, now has an experimental branch

Short version: **the `main` branch of this repository still does not include
Broadcom's Flow Accelerator (FA)/Cut-Through Forwarding (CTF) offload**, for
the same reason as before - nobody has written or validated R8000 enablement
for it. But a 2026-11-22 re-investigation (re-reading
[openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789) in
full, its actual diff and commit history, current discussion, and the
upstream kernel work it points at) found the gap for this specific board is
narrower than the first pass concluded, found a plausible, small,
R8000-specific patch to close it, and - because the user explicitly asked for
real hardware-offload work to be built, not just re-documented - that patch
now exists, clearly marked experimental, on a **separate, non-default branch
that nothing in this repository's automation can build without a person
deliberately choosing it.** See [What's new: the experimental
branch](#whats-new-the-experimental-branch) below.

## What exists upstream (re-checked 2026-11-22)

[openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789),
"bcm53xx: offload flows to the Northstar flow accelerator," is still open,
still targets `main` (not any release branch), and is substantially more
advanced than when this was first read:

| | First pass (2026-11-18ish) | Now (2026-11-22) |
|---|---|---|
| Commits | fewer, earlier state | **20 commits**, head `c25b1f2b53290e5358c56542bafbaf2edc748282` on `egc112/openwrt` branch `bcm53xx-fa`, last pushed **2026-11-21** |
| Approving reviews | 1 of 6 required | **2 of 6 required** (one from `lorand-horvath`; GitHub's own sidebar still states "At least 6 approving reviews are required to merge this pull request") |
| Boards with real FA enablement | Linksys EA6900 (BCM4708), ASUS RT-N18U | EA6900, RT-N18U, **and now Netgear R6400 v1/v2** (via the now-merged prerequisite openwrt/openwrt#25131, "use IMP0 port 8 as the CPU port," 31 files, 30 boards) |
| Measured throughput | 941 Mbit/s / 97% idle, EA6900 only | Retested on EA6900 **and R6400 v2**: "IPv4 941/941, IPv6 928/928 Mbit/s at 97-98% idle," plus a described race-condition stress test ("no misdelivered packet in a table race test under line-rate traffic") |
| Upstream kernel driver | mentioned as "in progress" | **Posted**: Florian Fainelli (Broadcom's own upstream maintainer) has a 9-patch series on the netdev mailing list (`patchwork.kernel.org/project/netdevbpf/list/?series=1213213`, title "net-next 0/9") - this investigation could not read its content directly (`lore.kernel.org` and `patchwork.kernel.org` both serve an Anubis bot-protection challenge to automated fetches from this environment), but the PR's own current text names it explicitly and says OpenWrt should switch to it once merged |

The driver (`drivers/net/ethernet/broadcom/bgmac-fa.c`, 237 lines) is still a
clean-room reimplementation of Broadcom's GPL-released `et` reference driver
(`etc_fa.c`/`fa_core.h`, ISC-licensed), not a binary blob - the author
maintains a detailed, fact-by-fact [PROVENANCE.md](https://github.com/egc112/Broadcom/blob/main/northstar-fa/PROVENANCE.md)
naming every source (specific commits of `FreshTomato-Project/freshtomato-arm`
and `mirror/dd-wrt`) and every claim that goes beyond what Broadcom's code
does (IPv6 support, routing-without-NAT, VLAN handling), each with how it was
verified by experiment on real hardware. Nothing here changes that
assessment: it is still legitimate, auditable work, just not yet merged.

## The R8000-specific finding that changes the picture

The first pass found "the R8000 is conspicuously absent" from the PR's file
list and concluded nobody had done R8000 enablement - true, but incomplete.
Reading the **current upstream `bcm4709-netgear-r8000.dts`** directly (not
the PR's diff, the actual file already in mainline Linux and in this
repository's pinned OpenWrt tree) shows why it is absent from one specific
patch, and shows the board is structurally closer to FA-ready than that
framing suggested:

```dts
&srab {
	status = "okay";
	ports {
		port@0 { label = "lan1"; };
		port@1 { label = "lan2"; };
		port@2 { label = "lan3"; };
		port@3 { label = "lan4"; };
		port@4 { label = "wan"; };
		port@5 {
			status = "disabled";
			fixed-link { speed = <1000>; full-duplex; };
		};
		port@7 { status = "disabled"; fixed-link { speed = <1000>; full-duplex; }; };
		port@8 { label = "cpu"; };
	};
};
```

Compare this against what the PR's prerequisite patch
(`376-ARM-dts-BCM5301X-use-IMP0-port-8-as-the-CPU-port.patch`) does to 30
*other* BCM5301x boards: move their CPU port from the switch's port 5 (or 7)
to port 8 (IMP0), because port 8 is where the flow accelerator sits. That
patch's own commit message says this "...the layout
`bcm47094-netgear-r8500.dts` already uses" for the boards that didn't need
it. **The R8000 is one of those boards: it already has `port@8 { label =
"cpu"; }` and port 5 already disabled - this is why patch 376's 30-file list
does not include it, not because the R8000 was skipped over.** The same is
true of the R7000 (confirmed directly from its upstream dts).

That means the two pieces actually missing for the R8000, going by the exact
shape of what the PR added for the EA6900, are small:

1. **`328`-equivalent** (tag the CPU port): add
   `dsa-tag-protocol = "brcm-prepend";` to `port@8`, 2 lines.
2. **`329`-equivalent** (trap port for FIN/RST/TTL-1): change `port@5` from
   `status = "disabled";` to the same `dsa-tag-protocol` line, **keeping**
   the `fixed-link` block - which, unlike the EA6900's starting point (plain
   `status = "disabled";`, no `fixed-link`), **the R8000 already has
   verbatim**. The R8000's port 5 is already defined exactly as a spare,
   gigabit, fixed-link switch port waiting to be used - the same pattern
   PROVENANCE.md describes b53's FIN/RST/TTL-1 trap rule using.

This is a materially smaller, better-understood gap than "nobody has written
R8000 enablement" implied: it is not fresh engineering, it is the same
roughly-15-line pattern already reviewed, measured, and shipped (pending
merge) for three other BCM5301x boards, applied to a fourth board whose
switch devicetree already carries the prerequisite layout.

## What is still genuinely unverified (and cannot be verified without hardware)

1. **Whether the R8000's BCM4709A0 physically has the FA silicon block at
   all.** The driver's own probe function is instructive here and was read
   in full:
   ```c
   void bgmac_fa_probe(struct bgmac *bgmac)
   {
           struct bcma_device *gmac3 = bcma_find_core_unit(core->bus, BCMA_CORE_MAC_GBIT, 3);
           if (!gmac3)
                   return;   /* no FA: bgmac->fa stays NULL, fa_open stays unset */
           ...
   }
   ```
   The FA's registers live inside a fourth GMAC core unit (GMAC3) on the
   SoC's internal bus; if that core unit is not present in a given chip's bus
   scan, the driver silently does nothing - `bgmac_open()` only calls
   `fa_open()` `if (bgmac->fa_open)`. **This is reassuring: on a chip
   without the FA block, this patch set is a safe no-op, not a crash.** But
   it also means the only way to know if BCM4709A0 has GMAC3 wired up is to
   read `dmesg`/the bus scan on a real one - BCM4709 is generally documented
   as a higher-tier part than EA6900's BCM4708 within the same family (more
   GMACs, more USB), which makes it *plausible* this core exists, but that is
   an inference from product-tier naming, not a confirmed fact for the exact
   BCM4709A0 stepping this router uses.
2. **What happens if GMAC3 exists but the register semantics do not match
   exactly** (a different switch/FA silicon revision than EA6900's). If
   `bcma_core_is_enabled()` passes but `bgmac_fa_setmode()`'s register writes
   don't produce the expected `FA_STATUS_INIT_DONE` bits within its 50 ms
   poll, `bgmac_fa_open()` returns an error, and **`bgmac_open()` aborts
   before `bgmac_chip_reset()`/`bgmac_dma_init()` run** - i.e. the Ethernet
   interface the CPU port sits behind would fail to come up at all on boot,
   not silently degrade. This is recoverable (CFE/NMRP recovery, not a
   brick), but it is a real "no wired networking until you recover" failure
   mode, not a purely cosmetic one - exactly the kind of thing that must not
   be tried on a router that is currently in production use.
3. **A reliable switch-revision check that does not require building
   anything turns out not to exist either**, on closer reading of the b53
   driver the R8000 actually uses. The generic `b53_switch_register()`
   logs `"found switch: %s, rev %i\n"` using `dev->core_rev`, which *is*
   genuinely how the EA6900 commit message's "switch revision 3" claim was
   checked - but only on the generic MDIO-attached b53 path
   (`b53_switch_detect()` reads the revision register before calling it).
   The R8000 (like all BCM5301x boards) uses `b53_srab.c`, which sets
   `chip_id` from the devicetree `compatible` string's match-table data
   *before* `b53_switch_register()` runs, short-circuiting
   `b53_switch_detect()` entirely - so **`core_rev` is never read on this
   board family, and that dmesg line would print "rev 0" regardless of the
   real silicon revision.** There is no already-available, zero-risk command
   to run on the current production router that confirms or rules out FA
   hardware presence; this would need either new debug code or waiting to
   boot the experimental branch's kernel (whose own probe/open path above is
   the actual, safe test).

## What's new: the experimental branch

Given the above - a small, well-understood, plausible patch, but a few facts
that are genuinely unknowable without running it on a real R8000 - this
repository now has a branch, **`experimental/bcm53xx-hw-offload`**, carrying:

- An `upstream/openwrt.conf` that, **on that branch only**, points at
  `egc112/openwrt.git` branch `bcm53xx-fa`, pinned to commit
  `c25b1f2b53290e5358c56542bafbaf2edc748282` (2026-11-21) instead of official
  `openwrt-25.12` - because the FA driver series does not exist on any
  official OpenWrt branch yet. This is a materially less stable base than
  `main`'s pin: it tracks OpenWrt `main` (currently kernel 6.18, vs. this
  repository's stable `openwrt-25.12` pin on kernel 6.12) plus an individual
  contributor's actively-changing, unmerged fork.
- A new patch, `patches/0003-...-netgear-r8000-flow-accelerator-EXPERIMENTAL.patch`,
  the ~15-line DTS change described above, with an explicit "UNTESTED, may
  not work, may prevent networking from starting - see docs/ctf-fa.md" banner
  in its own commit message, not just in this document.
- `docs/experimental-hw-offload-branch.md` on that branch, spelling out
  exactly what differs from `main` and the safety boundary below.

**Why a branch, not a profile flag or a package toggle:** this change is a
devicetree/kernel patch, not a userspace package - there is no `opkg`/`apk`
toggle to wrap it in the way `overlays/common`'s software flow offloading or
SQM are toggled. The existing package-profile mechanism
(`profiles/*.packages`) cannot gate a kernel patch. A branch is the smallest
change that makes activation require a deliberate, separate action: building
`main` (what `scripts/build.sh` and the default GitHub Actions inputs do)
never touches this code at all.

**Why this cannot build or ship by accident:**

- `.github/workflows/build.yml` triggers on `workflow_dispatch` (manual) and
  `schedule` (cron) only - there is no `push` trigger, so pushing this branch
  does not start a build.
- GitHub Actions' `schedule` trigger **only ever fires on the repository's
  default branch** (`main`), which this branch is not and will not become
  without a separate, deliberate repository-settings change. The daily
  automated build will never touch it.
- `workflow_dispatch` requires a person to explicitly pick this branch from
  the "Use workflow from" dropdown before running it - the default selection
  is always the branch the UI is opened from (`main`).

**The safety boundary this was built under, stated plainly:** the physical
R8000 this repository is for is currently the user's production router while
a FriendlyElec R76S is set up as its replacement. Nothing on this branch has
been built, flashed, or tested, and nothing about this commit changes that -
it adds code and documentation, not a validated feature. Do not build or
flash this branch until the R76S is confirmed working as the main router and
this R8000 is free to experiment on and recover if networking does not come
up. When it is: build it, watch `dmesg` for `bgmac_fa_probe`/`bgmac_fa_open`
messages on first boot (`flow accelerator: GMAC3 core is not enabled`, `flow
accelerator: no table init`, or `flow accelerator in the path (prepended
tag)` are the three outcomes to look for), and have the NMRP/serial recovery
path (see the main README's [Recovery](../README.md#recovery) section) ready
before that first boot, exactly as for any other change on this hardware.

## What this means for throughput today (`main` branch, unchanged)

Without FA, wired routing/NAT on this platform runs through the normal Linux
networking stack plus the generic software flowtable fastpath
(`flow_offloading`, turned on by default - see the README's "Hardware
acceleration" section and
`overlays/common/etc/uci-defaults/10-flow-offloading`). Community reports on
other bcm53xx devices (a Phicomm K3, with Broadcom's older CTF rather than
FA) have reached close to wire speed on a single gigabit link; this build's
baseline should be in a similar range, but that has not been measured on an
R8000 running this image.

## If you want to pursue this yourself

- Watch [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789)
  (now needs 4 more approving reviews to merge) and Florian Fainelli's
  upstream netdev series; either landing would be a far better foundation
  than this repository's experimental branch, which should be retired in
  favor of whichever lands first.
- If you want to go further than this repository's experimental branch
  already does: the open questions above (GMAC3 presence on BCM4709A0,
  register-level compatibility) are exactly what
  [egc112/Broadcom](https://github.com/egc112/Broadcom)'s `northstar-fa`
  research methodology (reading hardware state back under a stock/DD-WRT
  boot, documented in its `PROVENANCE.md`) was built to answer for other
  boards - the same method, run on a free R8000, would answer them here
  too, and would be worth reporting back to that PR.
