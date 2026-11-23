# Known issues, caveats, and where each one comes from

## Wi-Fi chip: this is BCM43602, not BCM4366

OpenWrt's own `target/linux/bcm53xx/image/Makefile` builds the R8000 with
`BRCMFMAC_43602A1` (`brcmfmac-firmware-43602a1-pcie`) for all three radios -
**not** BCM4366, which is what the R8500, R7800, R8300 and R7500 (a
different, Qualcomm-based board entirely) use. The mainline device tree's
`wifi@0,0` nodes do list `compatible = "brcm,bcm4366-fmac", "brcm,bcm4329-fmac"`
for the R8000 too, but that `compatible` string is a generic placeholder
reused across many bcm53xx boards' PCIe Wi-Fi nodes regardless of the actual
silicon - firmware selection is driven by the PCI vendor/device ID brcmfmac
probes at runtime, not by that DT string, and OpenWrt's own package selection
for this specific device (which does drive what firmware actually ships) says
43602a1. If you see "BCM4366" for the R8000 elsewhere, including in the
planning notes for this repository, that is almost certainly carried over
from the R8500/R7800 (same "Nighthawk X" family, genuinely different Wi-Fi
silicon) rather than this board. `patches/0001` and `patches/0002` are both
written and verified against BCM43602.

## Guest networks / multi-SSID: patches/0002

Confirmed root cause (verified directly against the exact pinned kernel
source this build uses, not just reported secondhand): BCM43602 firmware
7.35.177.56 (on the R8000) does not answer `brcmfmac`'s `interface_create`
version query. `brcmf_cfg80211_request_ap_if()` treats that failure as fatal
and returns early, even though the same function's legacy `bsscfg:ssid` MBSS
path - a few lines further down, reached by the same code path that already
runs when the query *succeeds* but reports an unsupported version - works
fine for this firmware once reached. `patches/0002` removes the early
return, letting the existing fallback run. See the patch itself for the full
explanation and `package/kernel/mac80211/patches/brcm/861-*.patch` for the
one-line kernel-side diff.

## 5 GHz radios: patches/0001

Also verified against the exact pinned source. `package/utils/nvram/files/nvram-bcm53xx.init`
already has a `set_bcm43602_variables()` case for the ASUS RT-AC3200 (the
same chip family, same triple-radio layout) but had no case at all for
`netgear,r8000`, so none of the three radios' PCIe devpath/devid/boardrev/
sromrev/boardflags bindings were ever set. Some community discussion of this
device concluded the 5 GHz calibration was unrecoverably baked into a
proprietary driver binary; it is not - it is a missing table entry, the same
class of fix the table already carries for several other boards.

The per-radio values in `patches/0001` were extracted from one physical unit
by the [88plug/netgear-r8000-plus](https://github.com/88plug/netgear-r8000-plus)
project. `devid`/`sromrev`/`boardrev`/`boardflags`/`devpath` describe the
chip and board wiring and should be constant across the model; actual
per-unit RF calibration and MAC addresses come from the factory `0:ART`
partition, which this patch does not touch. No controlled A/B test (flash
plain upstream OpenWrt, compare) was run by that project to prove this table
entry is the sole cause of 5 GHz working, so treat it as a well-targeted,
low-risk fix rather than an independently proven root cause for every
unit/revision - if your unit's 5 GHz radios already came up fine on plain
upstream OpenWrt, this patch sets the same values and should be harmless
either way.

## SQM

`overlays/common/etc/hotplug.d/iface/32-dynamic-wan-sqm` creates a `cake`
queue for any WAN-side (masquerading) firewall zone automatically, bound to
its current device name - but ships it **disabled**, with `download`/`upload`
left at `0`. This is deliberate: guessing a bandwidth number and shipping it
enabled risks silently shaping someone's gigabit connection down to whatever
placeholder number was picked. After first boot, set your actual measured
up/down speed (in kbit/s, ~85-95% of your real link) and enable it, in LuCI
(*Network > SQM QoS*) or:
```sh
uci set sqm.sqm_wan.download='91000'   # your real download, kbit/s
uci set sqm.sqm_wan.upload='9000'      # your real upload, kbit/s
uci set sqm.sqm_wan.enabled='1'
uci commit sqm
/etc/init.d/sqm restart
```
(`sqm_wan` assumes your WAN zone's logical interface is named `wan`; the
hotplug script names the section after whatever it actually is.)

## Radio watchdog

`overlays/common/etc/init.d/radio-watchdog` and
`overlays/common/usr/sbin/radio-watchdog-check` (cron, every 5 minutes) react
to known `brcmfmac` firmware-wedge log signatures
([openwrt/openwrt#14685](https://github.com/openwrt/openwrt/issues/14685),
[#20514](https://github.com/openwrt/openwrt/issues/20514)) by escalating
`wifi reload` -> a full module reload -> a rate-limited reboot (once per 6
hours) within a rolling 1-hour window. This is a mitigation for a real,
recurring hardware/firmware ceiling on BCM43602 + `brcmfmac` that the
88plug/netgear-r8000-plus project's own engineering log describes as having
"no known permanent driver fix as of 25.12.5" - not something this build
claims to have solved. Disable it with
`/etc/init.d/radio-watchdog stop && /etc/init.d/radio-watchdog disable` if
you would rather not have an automatic reboot path at all, or if its
escalation ever fights with something else you run.

## WPA3-SAE, OWE, and DFS channels

Not specific to this build, but worth knowing before you rely on them:
independent, over-the-air testing by the 88plug/netgear-r8000-plus project
found this firmware/driver combination never actually broadcasts SAE (WPA3
personal) even when configured - scans showed PSK/PSK-SHA256 only - and that
OWE (Enhanced Open) and DFS channels are unsupported at the firmware level
(`BCME_UNSUPPORTED`, not a driver or config gap). 802.11k/v and management
frame protection are unaffected. This build does not attempt to work around
any of the three; they are firmware limits, not something a patch fixes.

## sysupgrade config loss (general OpenWrt issue, not this build's bug)

[openwrt/openwrt#21655](https://github.com/openwrt/openwrt/issues/21655): a
config-preserving `sysupgrade` can, rarely, reset `/etc/config/{wireless,
firewall,sqm,system}` to defaults on some devices with no warning either way.
Back up your configuration (`sysupgrade -b backup.tar.gz`) before any
upgrade, and check the running config afterwards rather than assuming a
successful-looking upgrade preserved everything.
