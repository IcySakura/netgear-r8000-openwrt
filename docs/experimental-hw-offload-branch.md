# The `experimental/bcm53xx-hw-offload` branch

You are reading this because you checked out, or are considering building,
the `experimental/bcm53xx-hw-offload` branch. It does not build the same
thing as `main`. Read this whole document first.

## Status 2026-11-24: built and flashed once - read this first

- Re-pinned to the PR head `e124ccf5d7` (2026-11-24). Since that head the PR
  keeps `brcm-prepend` out of device trees (a preinit hook switches the tag
  at boot only when `flow_offloading` and `flow_offloading_hw` are both on),
  so `patches/0003` is now just "enable port 5" (gmac0, fixed link, the trap
  port) plus `/lib/preinit/99_30_fa_trial`: `touch /etc/fa-trial` before a
  reboot and `flow_offloading_hw` is reset to 0 in the saved config right
  after the tag hook has used it, so a hang or watchdog reset after enabling
  the accelerator boots the next time without it.
- The FA hardware is present on the R8000 (GMAC3 core in `bcma`, `found
  switch: BCM53012, rev 5`; rev >= 3 is Broadcom's `FA_CAPABLE`).
- Built locally (the PR's own `feeds.conf.default`, i.e. OpenWrt `main`
  feeds, not `upstream/feeds.conf`'s 25.12 pins; + `ethtool`, `iperf3`) and
  flashed with `sysupgrade` keeping settings, FA **off**. Result: it booted,
  took its WAN lease, routed and NATed (a forwarded test port worked), but
  **nothing answered on 192.168.50.1:22 or :443** (the kernel itself sent
  the RSTs - their TOS echoed the SYN's - so dropbear and uhttpd were not
  listening, not a firewall reject). The cause is unknown; the router could
  not be managed remotely and the accelerator was never switched on.
  Before flashing this again: have LAN/serial access, check
  `logread | grep -E "dropbear|uhttpd"` on first boot, and consider flashing
  without keeping settings (`sysupgrade -n`) from a LAN-side shell - the
  25.12 config may be what main's packages choke on.

## What this branch is, in one sentence

An attempt at real Broadcom hardware packet offload (the Northstar Flow
Accelerator, "FA") for the Netgear R8000, built on top of an unmerged
upstream pull request, with a new R8000-specific devicetree patch written by
this repository - **none of it built, flashed, or tested on real hardware.**

## Why it exists

`docs/ctf-fa.md` on `main` has the full investigation. Short version: the
R8000's upstream devicetree already has the one prerequisite
([openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789)'s
other boards needed added (switch port 8 as the CPU port), making the
remaining R8000-specific gap a small, well-understood ~15-line patch instead
of fresh engineering - so when asked to dig deeper and build toward real
hardware offload rather than just re-document why it's missing, this was
small and well-grounded enough to actually write, provided it stayed
completely out of anything that could be built or flashed by accident.

## Exactly what is different from `main`

| | `main` | This branch |
|---|---|---|
| Upstream pin | Official OpenWrt, `openwrt-25.12`, a stable release branch | `egc112/openwrt.git` branch `bcm53xx-fa`, an individual contributor's fork of OpenWrt `main`, carrying an unmerged, actively-changing pull request |
| Kernel | 6.12 | 6.18 |
| Patches | `0001` (5 GHz NVRAM fix), `0002` (brcmfmac MBSS fallback) | Same two, **unverified against this base** (see `upstream/openwrt.conf`'s own comments), plus `0003`: the new, untested R8000 flow-accelerator devicetree patch |
| CTF/FA driver | Not present | Present (vendored via the upstream pin, not copied into this repository - `drivers/net/ethernet/broadcom/bgmac-fa.c` and ~30 supporting kernel/DSA/b53 patches, all from the pinned fork commit) |
| CI | Builds daily (schedule) and on manual dispatch from `main` | **Never builds automatically** - see below |

## The safety boundary (read this part even if you skim everything else)

The physical Netgear R8000 this repository is for is **currently the user's
production router**, a temporary stand-in while a FriendlyElec R76S is set up
as the permanent replacement. This branch was written under an explicit
instruction: do the research, write the code, **do not imply any of it has
been validated, and make sure nothing here can become active without a
separate, deliberate action** once the R8000 is free to experiment on.

Concretely, that means:

1. **This branch is not `main` and will not become `main`** without someone
   deciding to merge it - which should not happen until it has actually been
   built and booted on a free R8000 and the outcomes in
   [What to actually do, once the hardware is free](#what-to-actually-do-once-the-hardware-is-free)
   below are known.
2. **GitHub Actions cannot build this branch by accident.**
   `.github/workflows/build.yml` has exactly two triggers: `workflow_dispatch`
   (a human clicks "Run workflow" and must explicitly pick this branch from
   the dropdown - the default is whatever branch the Actions UI is currently
   viewing) and `schedule` (a daily cron job that, by GitHub's own design,
   **only ever fires on the repository's default branch**). Neither can
   select this branch without a person choosing to.
3. **Nothing about this patch is reversible-by-accident once flashed, either**
   - it is a devicetree change, which only takes effect in an image actually
     built from this branch. An image built from `main` never contains it.

## What the new patch actually does, and the two things nobody has confirmed

`patches/0003-bcm53xx-dts-netgear-r8000-flow-accelerator-EXPERIMENTAL.patch`
adds one nested kernel patch
(`target/linux/bcm53xx/patches-6.18/398-...-EXPERIMENTAL.patch`) that:

- Tags switch port 8 (the R8000's existing, already-in-use CPU port) with
  the flow accelerator's `brcm-prepend` DSA protocol.
- Turns the R8000's existing, already-disabled, already-fixed-link port 5
  into the flow accelerator's trap port (for TTL-1 and TCP FIN/RST frames the
  accelerator itself cannot forward).

This mirrors, almost line for line, patches `328` and `329` of the upstream
PR (written for the Linksys EA6900), because the R8000 turns out to already
have the devicetree prerequisite those patches assume. It was verified to
apply cleanly (`git apply --check` and a byte-for-byte diff against the
actual pinned `bcm4709-netgear-r8000.dts`) before being committed - that is
the limit of what could be verified without hardware.

**Two things this patch cannot confirm, and that only a real R8000 can:**

1. **Whether the BCM4709A0 physically has the flow accelerator silicon
   block at all.** The upstream driver's own probe function
   (`bgmac_fa_probe()` in `bgmac-fa.c`) looks for a fourth GMAC core unit
   (GMAC3) on the SoC's internal bus; if it is not there, the driver quietly
   does nothing; `bgmac_open()` only calls into FA code `if
   (bgmac->fa_open)`, which stays unset. **This is the safe outcome** - the
   CPU port keeps working exactly as on `main`, just with an unused tag
   property.
2. **Whether, if the block is there, its registers behave the way the
   EA6900's (BCM4708, a different member of the same chip family) do.** If
   `bgmac_fa_setmode()`'s table-initialization poll does not see the status
   bits it expects within 50 ms, `bgmac_fa_open()` returns an error, and
   `bgmac_open()` aborts **before** resetting the chip or starting DMA - the
   CPU port's Ethernet interface does not come up at all. This is the one
   outcome that is not harmless: it means no wired networking through that
   interface until the devicetree change is reverted (or the image is
   reflashed back to `main`). It is recoverable the same way any other bad
   change on this hardware is (see the main README's
   [Recovery](../README.md#recovery) section, NMRP or serial), not a brick -
   but it is real downtime, which is exactly why this must never be the first
   thing flashed onto a router anyone depends on.

## What to actually do, once the hardware is free

1. Confirm the R76S is working as the main router first. This is not
   optional - it is the entire reason this stayed on a branch instead of a
   `main`-branch toggle.
2. Read `docs/ctf-fa.md`'s current state of
   [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789) -
   it may have been merged, superseded by Florian Fainelli's upstream kernel
   driver, or moved since this branch was written; re-pin `upstream/openwrt.conf`
   accordingly before building if so (see that file's own comments on what
   re-pinning here involves).
3. Build this branch (`scripts/build.sh --profile default`, from this
   branch's checkout - note it will download and build against a different
   upstream commit than `main`'s build/ tree, so starting from a clean
   `build/openwrt` is simplest). Expect patch drift against `patches/0001`
   and `0002` to be possible; resolve it the same way `scripts/build.sh`
   already handles upstream drift (three-way merge), reading what actually
   changed rather than forcing it through.
4. Flash it with recovery ready (serial console or NMRP), exactly as the
   README's [Installing](../README.md#installing) section already describes
   for any image from this repository.
5. Watch `dmesg`/`logread` on first boot for one of three outcomes from the
   flow accelerator code:
   - `flow accelerator: GMAC3 core is not enabled` or no FA-related message
     at all -> the silicon is not present (or not enabled) on this unit;
     networking should otherwise work normally; FA offload is simply not
     available on this hardware. Revert to `main`.
   - `flow accelerator: no table init (status 0x...)` -> the silicon exists
     but did not behave as expected; **the CPU port's interface will not have
     come up** - recover and revert to `main`, and consider reporting the
     exact status value back to
     [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789).
   - `flow accelerator in the path (prepended tag)` -> it initialized.
     Confirm routing/NAT actually works before trusting throughput numbers,
     then measure (iperf3, LAN-to-WAN, both directions) and compare against
     this build's existing software-flow-offload baseline.
6. Only after that - a real result, not an assumption - would merging any of
   this into `main` (even as a default-off toggle) be appropriate.
