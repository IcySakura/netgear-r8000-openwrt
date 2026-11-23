# OpenWrt for the Netgear R8000 (Nighthawk X6, BCM4709A0)

> [!CAUTION]
> **You are on the `experimental/bcm53xx-hw-offload` branch.** It does not
> build the same thing as `main`: different upstream pin (an unmerged,
> individual contributor's fork, not official OpenWrt), a newer kernel, and
> one new, untested, EXPERIMENTAL devicetree patch attempting real hardware
> packet offload. Nothing on this branch has been built, flashed, or tested
> on real hardware. Read
> [docs/experimental-hw-offload-branch.md](docs/experimental-hw-offload-branch.md)
> in full before building or flashing anything from here. Everything else in
> this README describes `main`'s behavior, not necessarily this branch's.

OpenWrt built from official upstream (the `openwrt-25.12` branch - `bcm53xx`
is a mainline-supported target, there is no third-party fork to pin) for the
**Netgear R8000** only, with two board-specific bug fixes, software flow
offloading tuned as the reliable baseline, and every real package
[antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt)
needs so this router can become an adoptable access point in a UniFi
controller.

This repository is a build recipe, not a copy of OpenWrt: it pins an upstream
commit, adds two patches on top, and builds images with GitHub Actions (or
locally) from package profiles. It follows the same conventions as two other
personal build repositories
([linksys-mx4300-openwrt-nss](https://github.com/IcySakura/linksys-mx4300-openwrt-nss),
[redmi-ax3000-openwrt-nss](https://github.com/IcySakura/redmi-ax3000-openwrt-nss)),
**adapted for a completely different SoC vendor** - see
[Hardware acceleration reality](#hardware-acceleration-reality) for why this
one is not named "-nss" and does not behave like those two.

> [!WARNING]
> Experimental firmware for **the Netgear R8000 only** - not the R8000P,
> R7000, R7000P, R7900, R8500, R8300 or R7800 (different Wi-Fi chips; see
> [docs/known-issues.md](docs/known-issues.md)). **None of this has been
> flashed or tested on real hardware by this repository** (see
> [What's verified](#whats-verified-and-whats-not) below) - it is a build
> recipe that compiles cleanly and whose patches were verified against the
> exact pinned source, not a build with field reports. Take a full backup of
> every MTD partition before flashing, know your recovery path
> ([Recovery](#recovery)), and expect to be at the router for the first boot.

## What's verified, and what's not

| | |
|---|---|
| Builds (compiles, patches apply, packages resolve) | Verified by GitHub Actions on every push/schedule |
| `patches/0001` (5 GHz NVRAM fix) and `patches/0002` (guest-network MBSS fallback) apply cleanly to the exact pinned source | Verified directly against that source while writing this repository |
| Boots, Wi-Fi comes up, 5 GHz actually works, guest networks actually work | **Not tested** - the underlying values/fix are reused from or informed by [88plug/netgear-r8000-plus](https://github.com/88plug/netgear-r8000-plus)'s own hardware testing, not retested here |
| Software flow offloading throughput | **Not measured on this image**; a 2022-era community report on a different bcm53xx device (Phicomm K3, Broadcom's older CTF, not this build's software fastpath) reached close to wire speed - see [docs/ctf-fa.md](docs/ctf-fa.md) |
| Radio watchdog, dynamic SQM | Logic reviewed, not run on hardware |
| unifi-openwrt adoption | **Not tested** - nobody, as far as this investigation found, has run unifi-openwrt on any bcm53xx/`brcmfmac` device; see [docs/unifi-adoption.md](docs/unifi-adoption.md) |
| CPU overclocking | **Not implemented** - re-investigated 2026-11-22 directly against mainline Linux source (not just OpenWrt's tree): no cpufreq driver, no writable clock-rate path, and no platform PM code exist anywhere upstream for this SoC family. Conclusion unchanged, now backed by primary sources; see [docs/overclock.md](docs/overclock.md) |
| Hardware packet offload (CTF/FA) | **Not implemented on `main`** - re-investigated 2026-11-22: the upstream PR has moved (2 of 6 reviews, R6400 now also covered) and the R8000 turns out to already have the switch-port prerequisite the PR's other boards needed added. A small, explicitly experimental, untested patch now exists on the separate `experimental/bcm53xx-hw-offload` branch, which nothing in this repository's automation builds by default; see [docs/ctf-fa.md](docs/ctf-fa.md) |

## Hardware acceleration reality

The Linksys MX4300 and Redmi AX3000 repositories this one follows the
conventions of both run Qualcomm IPQ-series SoCs, where **NSS** (Network
SubSystem) is a real, documented Qualcomm packet-acceleration engine with
upstream `kmod-qca-nss-*` driver support - that is why "nss" is in their
names and why their images offload routing/NAT/Wi-Fi onto dedicated silicon.

**The R8000 uses a Broadcom BCM4709A0 SoC. There is no NSS, and no official,
mainline-supported hardware NAT/packet-offload block at all, on this
platform.** Broadcom's own proprietary CTF (Cut-Through Forwarding) and newer
FA (Flow Accelerator) exist on this chip family, but:

- CTF is legacy, closed, and has no mainline/OpenWrt driver for this target.
- FA has an **unmerged** community reimplementation
  ([openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789))
  that does not touch the R8000 at all and is not included here - see
  [docs/ctf-fa.md](docs/ctf-fa.md) for the full investigation, including why
  its headline "941 Mbit/s, 97% CPU idle" number is the PR author's own
  unverified claim, measured on a *different* router (a Linksys EA6900), not
  this board.

So this build's baseline is the generic path every OpenWrt target has:
**software flow offloading** (`firewall.@defaults[0].flow_offloading`,
turned on at first boot by `overlays/common/etc/uci-defaults/10-flow-offloading`).
`flow_offloading_hw` is deliberately left off: there is no hardware flowtable
on this SoC for it to offload to, and turning it on would be a silent no-op
at best. If you do not hit full gigabit, community reports on other bcm53xx
devices point at disabling GRO as the actual lever on this platform, not flow
offloading itself (unverified by any OpenWrt maintainer - see
[docs/ctf-fa.md](docs/ctf-fa.md)).

Wi-Fi runs the real in-kernel `brcmfmac` driver (no vendor blob situation) on
three BCM43602 radios - see [docs/known-issues.md](docs/known-issues.md) for
why this is BCM43602, not the BCM4366 sometimes associated with this router.

## What this build adds to upstream

- **5 GHz radio fix** (`patches/0001`): adds the Netgear R8000's missing
  BCM43602 board-ID entry to `nvram-bcm53xx.init`. See
  [docs/known-issues.md](docs/known-issues.md).
- **Guest network / multi-SSID fix** (`patches/0002`): lets `brcmfmac` fall
  back to its existing legacy MBSS path when the firmware predates the
  `interface_create` version query, instead of refusing to create a second
  AP BSS at all. See [docs/known-issues.md](docs/known-issues.md).
- **Software flow offloading, tuned as the baseline** (`overlays/common`):
  on by default; see [Hardware acceleration reality](#hardware-acceleration-reality).
- **Dynamic, safe-by-default SQM** (`overlays/common`): a `cake` queue is
  created automatically for your WAN zone, bound to its current device name,
  but shipped disabled until you set your real bandwidth. See
  [docs/known-issues.md](docs/known-issues.md).
- **A radio watchdog** (`overlays/common`): reacts to known `brcmfmac`
  firmware-wedge log signatures by escalating `wifi reload` -> a module
  reload -> a rate-limited reboot. See [docs/known-issues.md](docs/known-issues.md).
- **Every real dependency of antoniocosta/unifi-openwrt** (`configs/r8000.config`,
  `configs/base.packages`): full `wpad`, `hostapd-utils`, `kmod-nft-bridge`,
  `kmod-veth`. unifi-openwrt itself is installed after first boot, following
  its own README - see [docs/unifi-adoption.md](docs/unifi-adoption.md) for
  why and exactly how.
- **Deliberately not included on `main`**: hardware packet offload
  ([docs/ctf-fa.md](docs/ctf-fa.md)) and CPU overclocking
  ([docs/overclock.md](docs/overclock.md)) - both investigated twice (most
  recently 2026-11-22, digging into mainline Linux source for overclocking
  and the actual PR diff/history for offload), neither safe to ship on
  `main` the way this repository's two reference repositories ship their own
  SoC-specific versions of these features. Overclocking has no mechanism to
  attach to anywhere upstream, full stop. Hardware offload has a small,
  plausible, R8000-specific patch now written and committed - but only on
  the separate, non-default **`experimental/bcm53xx-hw-offload`** branch,
  untested, with no automation that can build or flash it without a person
  deliberately choosing that branch. Read those two documents before
  assuming either is just "missing."

## Hardware

| | |
|---|---|
| SoC | Broadcom BCM4709A0, dual-core ARM Cortex-A9 @ ~1 GHz |
| RAM | 256 MB |
| Flash | 128 MB NAND (SPI-NAND, `bcm53xx`/`generic` target) |
| Wi-Fi | 3x BCM43602 (`brcmfmac`, in-kernel driver) - 1x 2.4 GHz, 2x 5 GHz |
| Switch | Broadcom `b53` SRAB, 4x LAN + 1x WAN gigabit |
| USB | 1x USB 2.0, 1x USB 3.0 |

Flash is not a constraint for this build: a base image is on the order of
9 MB, leaving well over 100 MB of headroom even with every package this
repository adds.

## Installing

### From the stock Netgear firmware

Follow the [OpenWrt wiki's Netgear R8000 page](https://openwrt.org/toh/netgear/r8000)
for the current, board-specific flashing procedure (the stock web UI accepts
a `.chk` image directly on this device family; some Netgear firmware versions
require a same-or-older-looking version string to accept a third-party image
- the wiki page is the authoritative, maintained source for any such quirk,
which this repository does not attempt to duplicate). Take a full NVRAM/flash
backup first if your stock firmware's web UI offers one.

### From OpenWrt (already running stock OpenWrt or an earlier build of this repository)

1. Back up your configuration: `sysupgrade -b backup.tar.gz` (copy it off the
   router).
2. Flash the profile's image with `sysupgrade`, or LuCI's *System > Backup /
   Flash Firmware*, keeping settings. Compare the SHA256 LuCI shows against
   the release's `sha256sums`.

**This firmware has no A/B partition or trial-boot mechanism** (unlike the
two repositories this one follows the conventions of, whose SoCs' own
bootloaders support it) - a bad flash is recovered the way any OpenWrt router
on this hardware is, via [Recovery](#recovery) below, not via an automatic
rollback. **This release is not cryptographically signed** for the same
reason those two repositories sign theirs (a trusted update path into an
automatic rollback) does not apply here; verify `sha256sums` yourself before
flashing.

## Upgrading

Settings are kept across a `sysupgrade`-based upgrade when you do not pass
`-n`. **Packages installed with `opkg`/`apk` by hand are not** - an upgrade
replaces the whole system image; put anything you want to keep into a
profile (see [Packages](#packages)) so the image you upgrade to already has
it. See [docs/known-issues.md](docs/known-issues.md) for a known, general
OpenWrt issue where a config-preserving upgrade can occasionally reset
specific config files - back up first regardless.

## Packages

### What the images contain

| Layer | File | Contents |
|---|---|---|
| Base | `configs/r8000.config` | Target selection, full `wpad` (not `wpad-basic-*`, a hard unifi-openwrt requirement) |
| Every profile | `configs/base.packages` | LuCI, unifi-openwrt's remaining real dependencies (`hostapd-utils`, `kmod-nft-bridge`, `kmod-veth`), SQM, diagnostics |
| One profile | `profiles/<name>.packages` | What that profile adds or leaves out |

Profiles in this repository:

| Profile | Contents |
|---|---|
| `default` | Everything above, nothing more |
| `minimal` | Drops the unifi-openwrt dependencies, SQM, and diagnostics - a plain router/AP image for anyone who does not want this router to become a UniFi AP |

The complete package list of an image is on a running router in
`apk list --installed`; the router also keeps the profile it was built from
in `/etc/r8000/profile.packages`.

### Adding or removing packages

1. Fork this repository (or work in your copy).
2. Edit a profile, or copy one to `profiles/<your-name>.packages`. One
   package per line, `#` starts a comment:
   ```
   # add a package
   luci-app-nlbwmon
   # leave out a package the base or another layer includes
   -tcpdump
   ```
   Package names are those of the OpenWrt feeds: search them with `apk
   search` on a router, in [the OpenWrt package table](https://openwrt.org/packages/start),
   or with `make menuconfig` in `build/openwrt` after a local build.
   Dependencies are added automatically.
3. Build: push and run *Actions > Build firmware* with your profile in
   **profiles**, or locally `scripts/build.sh --profile <your-name>`.
4. Install the new image ([Upgrading](#upgrading)).

The build **fails** if a listed package does not make it into the image
(unknown name, missing feed, unmet dependency), so an upgrade never drops
software silently.

To turn what a running router has into a profile:
```sh
scripts/router-packages.sh root@<router> > profiles/my-router.packages
```

### Your own packages / other feeds

Packages can come from any feed in `upstream/feeds.conf`. To use a
third-party feed, add it there pinned to a commit, then list its packages in
a profile:
```
src-git myfeed https://github.com/<owner>/<repo>.git^<commit>
```
`scripts/bump-upstream.sh` only moves the official OpenWrt feeds already in
`upstream/feeds.conf`; move the pin of your own feeds by hand. Check a
feed's licence before publishing images built with it.

## Building

### GitHub Actions

*Actions > Build firmware > Run workflow* builds the profiles you name
(default: `default minimal`) in one tree, validates them, and publishes a
release:

- **upstream:** `pinned` builds `upstream/` as committed; `latest` first
  moves it to the current `openwrt-25.12` branch tip.
- **publish:** `testing` (a pre-release), `stable`, or `none` (images only as
  a workflow artifact).

**Automatic builds.** Every day the workflow runs `scripts/bump-upstream.sh`:
unlike the two repositories this one follows, there is no third-party
builder's own releases to track - it simply moves `OPENWRT_COMMIT` (and the
official feeds) to the current tip of `openwrt-25.12`. If anything moved, or
this repository has commits since the newest release (other than the
workflow's own pin commits), it builds and validates both profiles, publishes
them on the **testing** channel, and commits the new pins.

**When upstream moves under the patches.** If `patches/0001` or `0002` no
longer apply because upstream changed lines next to them, `scripts/build.sh`
merges them three-way from the commit they were written for and writes the
merged patches back; the workflow commits them with the new pins. If the new
upstream still does not build, the run holds it back instead of failing: it
builds the pinned upstream so the commits here still ship, and opens an
issue labelled `upstream-held` with the end of the build log.

### Locally

Linux with the [OpenWrt build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem),
`device-tree-compiler` and `squashfs-tools`; ~25 GB of disk.

```sh
scripts/build.sh                                      # profile "default"
scripts/build.sh --profile default --profile minimal   # several profiles, one tree
scripts/build.sh --clean                               # re-apply the patches from scratch
```

The tree goes to `build/openwrt`, downloads to `build/dl`, the images to
`out/<profile>/`. Each image is checked by `tools/validate-images.sh` (file
presence, checksum, config sanity) - static checks only; see
[What's verified](#whats-verified-and-whats-not).

## Recovery

This device's bootloader is Broadcom's CFE, not U-Boot - the
[OpenWrt wiki's Netgear R8000 page](https://openwrt.org/toh/netgear/r8000)
and the general [bcm53xx recovery guidance](https://openwrt.org/docs/techref/bootloader/cfe)
are the maintained, authoritative sources for this device's specific
procedures (NMRP recovery via `nmrpflash`, CFE's own TFTP recovery, and
serial console pinout), which this repository does not duplicate or
guarantee. In general, for this SoC family:

1. **NMRP recovery** (Netgear's recovery protocol, works even with a
   damaged/missing OS partition as long as CFE itself is intact): use
   [nmrpflash](https://github.com/jclehner/nmrpflash) from another computer
   on the same link, following its own README.
2. **Serial console** (UART, inside the case): interrupt CFE at boot and
   TFTP-boot a known-good image, as described on the OpenWrt wiki page above.

## Known limitations

See [docs/known-issues.md](docs/known-issues.md) for the full list with
sources: the BCM43602-not-BCM4366 chip correction, the two patches' real
scope and caveats, SQM, the radio watchdog, WPA3-SAE/OWE/DFS firmware limits,
and a general OpenWrt `sysupgrade` config-loss issue worth knowing about
regardless of this repository.

## Repository layout

```
upstream/openwrt.conf      pinned upstream tree (official OpenWrt, openwrt-25.12 branch)
upstream/feeds.conf        pinned official feeds
patches/                   0001: 5 GHz NVRAM board-ID fix; 0002: guest-network MBSS fallback
configs/r8000.config       base build configuration (diffconfig): target, full wpad
configs/base.packages      packages in every profile (unifi-openwrt deps, SQM, LuCI)
profiles/                  package profiles (*.packages): default, minimal
overlays/common/           files in every image: flow offloading, dynamic SQM, radio watchdog
docs/                      ctf-fa.md, overclock.md, unifi-adoption.md, known-issues.md,
                           experimental-hw-offload-branch.md (see the
                           experimental/bcm53xx-hw-offload branch)
scripts/build.sh           reproducible build of one or more profiles
scripts/bump-upstream.sh   move upstream/ to the current openwrt-25.12 tip
scripts/profile.sh         profile -> .config, and the post-defconfig check
scripts/router-packages.sh profile from a running router
tools/validate-images.sh   static checks of the images
.github/workflows/         GitHub Actions build and release
```

## Credits

- **[OpenWrt](https://openwrt.org)** - the operating system, the `bcm53xx`
  target, R8000 support, and the build system.
- **[88plug/netgear-r8000-plus](https://github.com/88plug/netgear-r8000-plus)** -
  the R8000's BCM43602 board-ID values (`patches/0001`) and the design this
  repository's SQM and radio-watchdog scripts are adapted from; its own
  engineering log is also the source for several of the firmware limitations
  documented in `docs/known-issues.md`.
- **[antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt)** -
  the UniFi-adoption agent this build's packages exist to support.
- **egc112 and strrs** - the FA/CTF offload investigation in
  [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789),
  read in full (diff, commit history and provenance record) for
  `docs/ctf-fa.md`; `main` does not include it, but their branch is the base
  the `experimental/bcm53xx-hw-offload` branch's R8000 patch is pinned on top
  of.
- **[IcySakura/linksys-mx4300-openwrt-nss](https://github.com/IcySakura/linksys-mx4300-openwrt-nss)**
  and **[IcySakura/redmi-ax3000-openwrt-nss](https://github.com/IcySakura/redmi-ax3000-openwrt-nss)** -
  the repository conventions (structure, scripts, documentation style) this
  one follows, adapted for a different SoC vendor with no NSS-equivalent
  hardware offload.

## License

GPL-2.0 (see `LICENSE`), the license of OpenWrt; files keep the license in
their own header where they have one. No proprietary firmware blobs are
vendored or fetched by this build beyond what OpenWrt's own `bcm53xx` target
already fetches for `brcmfmac`.
