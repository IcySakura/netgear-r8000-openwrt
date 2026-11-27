# OpenWrt for the Netgear R8000 (Nighthawk X6, BCM4709A0)

> This repository is **AI-assisted** and has undergone only **limited human review**. Inspect changes and test carefully before flashing.

> [!NOTE]
> **Branch: `experimental/bcm53xx-hw-offload`.** This branch tracks an unmerged upstream OpenWrt `main` fork (kernel 6.18) with Broadcom Northstar Hardware Flow Accelerator (`bgmac-fa`) support, the kernel 6.18 3rd-radio PCIe BAR fix, and Wi-Fi IRQ balancing. See [docs/experimental-hw-offload-branch.md](docs/experimental-hw-offload-branch.md). For official `openwrt-25.12` (kernel 6.12), use `main`.

OpenWrt build recipe for the **Netgear R8000** with board-specific Wi-Fi fixes, flow offloading, modernized LuCI (Footstrap + Dashboard), and all OpenWrt-side dependencies for [antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt).

> [!WARNING]
> For **Netgear R8000 only** — not the R8000P, R7000, R7000P, R7900, R8500, R8300, or R7800. Back up your configuration and MTD partitions before flashing, and keep [Recovery](#recovery) handy.

## Status

| Feature | Status |
|---|---|
| Builds (compiles, patches apply, packages resolve) | Tested |
| 5 GHz NVRAM fix (`patches/0001`) & multi-SSID fallback (`patches/0002`) | Tested |
| Kernel 6.18 3rd Wi-Fi radio PCIe BAR fix (`patches/0004`) | Tested |
| Broadcom Northstar Hardware Flow Accelerator (`patches/0003`) | Tested (~940 Mbit/s @ ~100% CPU idle, 742 Mbit/s @ MSS 300) |
| Wi-Fi IRQ balancing (`r8000-wifi-irq`) | Tested |
| `unifi-openwrt` adoption (`UHDIW`, `GOARM=7,softfloat`) | Tested |
| Radio watchdog & dynamic SQM | Included (SQM disabled until link speed is set) |
| CPU overclocking | Not included — see [docs/overclock.md](docs/overclock.md) |

## What this build adds to upstream

- **5 GHz radio fix (`patches/0001`):** Adds the R8000's BCM43602 board-ID entries to `nvram-bcm53xx.init`.
- **Multi-SSID / guest-network fix (`patches/0002`):** Enables `brcmfmac`'s legacy MBSS fallback for BCM43602 firmware `7.35.177.56`.
- **Hardware Flow Accelerator (`patches/0003`):** Enables switch port 5 as the Northstar Flow Accelerator trap port alongside 2 Gbps IMP0 port 8 (`eth2`). See [docs/experimental-hw-offload-branch.md](docs/experimental-hw-offload-branch.md).
- **3rd Wi-Fi radio PCIe BAR fix (`patches/0004`):** Fixes kernel 6.18 `pbus_size_mem()` window sizing for the PLX switch so all three BCM43602 radios initialize.
- **Wi-Fi IRQ balancing (`overlays/common`):** Pins `pcie0` (5 GHz High) to CPU0 and `pcie1` (2.4 GHz + 5 GHz Low) to CPU1.
- **Modernized LuCI web UI (`configs/base.packages`, `overlays/common`):** LuCI over HTTPS with the official **Footstrap** theme (set as default once on fresh installs or Bootstrap, preserving custom theme choices) and **LuCI Dashboard** as the status landing page.
- **Dynamic SQM & radio watchdog (`overlays/common`):** Auto-configured `cake` queue (shipped disabled until you set your bandwidth) and a `brcmfmac` wedge-recovery watchdog. See [docs/known-issues.md](docs/known-issues.md).
- **`unifi-openwrt` dependencies (`configs/r8000.config`, `configs/base.packages`):** Full `wpad-openssl`, `hostapd-utils`, `kmod-nft-bridge`, and `kmod-veth`. See [docs/unifi-adoption.md](docs/unifi-adoption.md).

## Hardware

| | |
|---|---|
| SoC | Broadcom BCM4709A0, dual-core ARM Cortex-A9 @ 1 GHz (softfloat, no FPU) |
| RAM | 256 MB |
| Flash | 128 MB NAND (`bcm53xx`/`generic`) |
| Wi-Fi | 3× BCM43602 (`brcmfmac`) — 1× 2.4 GHz, 2× 5 GHz (Low + High bands) |
| Switch | Broadcom `b53` SRAB (BCM53012), 4× LAN + 1× WAN Gigabit |
| USB | 1× USB 2.0, 1× USB 3.0 |

## Installing & Upgrading

- **From stock Netgear firmware:** Follow the [OpenWrt Netgear R8000 wiki](https://openwrt.org/toh/netgear/r8000) to flash the `.chk` image.
- **From OpenWrt:** Back up with `sysupgrade -b backup.tar.gz`, verify `sha256sums`, and flash via `sysupgrade` or LuCI (*System > Backup / Flash Firmware*).

> [!NOTE]
> This device has no A/B partition or automatic rollback, and releases are not cryptographically signed. Verify `sha256sums` before flashing. Manually installed packages are not kept across `sysupgrade` — add them to a profile in `profiles/*.packages` to include them in the image.

## Packages & Profiles

| Layer | File | Contents |
|---|---|---|
| Base | `configs/r8000.config` | Target selection, `wpad-openssl` |
| Every profile | `configs/base.packages` | LuCI (`luci-ssl-openssl`, `luci-theme-footstrap`, `luci-mod-dashboard`), `unifi-openwrt` dependencies, SQM, diagnostics |
| Profile | `profiles/<name>.packages` | Additions or exclusions (`-package-name`) |

Built-in profiles:
- `default`: Base packages as listed above.
- `minimal`: Drops `unifi-openwrt` dependencies, SQM, and diagnostics.

## Building

### GitHub Actions
Run *Actions > Build firmware > Run workflow* and choose the desired branch, profiles (default: `default minimal`), `upstream` (`pinned` or `latest`), and `publish` (`testing`, `stable`, or `none`). Daily scheduled builds run on `main` only.

### Locally
Requires Linux with the [OpenWrt build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem), `device-tree-compiler`, `squashfs-tools`, and ~25 GB of disk:

```sh
scripts/build.sh                                      # profile "default"
scripts/build.sh --profile default --profile minimal  # multiple profiles
scripts/build.sh --clean                              # re-apply patches cleanly
```

Images are written to `out/<profile>/` and checked by `tools/validate-images.sh`.

## Recovery

The R8000 uses Broadcom CFE. See the [OpenWrt Netgear R8000 wiki](https://openwrt.org/toh/netgear/r8000) and [CFE recovery docs](https://openwrt.org/docs/techref/bootloader/cfe):
1. **NMRP recovery:** [nmrpflash](https://github.com/jclehner/nmrpflash) over Ethernet.
2. **Serial console (UART):** Interrupt CFE and TFTP-boot a known-good image.

## Repository layout

```text
upstream/openwrt.conf      pinned upstream OpenWrt source
upstream/feeds.conf        pinned feeds
patches/                   board and kernel patches
configs/r8000.config       base diffconfig (target, full wpad)
configs/base.packages      packages included in every profile
profiles/                  package profiles (default, minimal)
overlays/common/           root filesystem overlay (UI defaults, offload, IRQ, SQM, watchdog)
docs/                      ctf-fa.md, overclock.md, unifi-adoption.md, known-issues.md,
                           experimental-hw-offload-branch.md
scripts/                   build.sh, bump-upstream.sh, profile.sh, router-packages.sh
tools/validate-images.sh   static image checks
.github/workflows/         GitHub Actions build and release
```

## Credits

- **[OpenWrt](https://openwrt.org)** — `bcm53xx` target and R8000 support.
- **[88plug/netgear-r8000-plus](https://github.com/88plug/netgear-r8000-plus)** — BCM43602 NVRAM board-ID values (`patches/0001`), SQM and radio-watchdog design, and firmware limitation notes.
- **[antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt)** — UniFi adoption agent.
- **egc112 and strrs** — Northstar Flow Accelerator driver in [openwrt/openwrt#26789](https://github.com/openwrt/openwrt/pull/26789).

## License

GPL-2.0 (see `LICENSE`).
