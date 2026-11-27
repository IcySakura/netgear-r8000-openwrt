# Known Issues and Caveats

## Wi-Fi silicon: BCM43602 (not BCM4366)

All three R8000 radios are **BCM43602** (`brcmfmac-firmware-43602a1-pcie`, firmware `7.35.177.56`), not BCM4366. The two 5 GHz radios have hardware RF band filters:
- **5 GHz Low (`radio2`):** channels 36–48
- **5 GHz High (`radio0`):** channels 149–165

## 5 GHz NVRAM fix (`patches/0001`)

Adds the R8000's BCM43602 board-ID entries (`devid`/`sromrev`/`boardrev`/`boardflags`/`devpath`) to `nvram-bcm53xx.init`. Per-unit calibration and MAC addresses remain in factory `0:ART`.

## Multi-SSID / guest networks (`patches/0002`)

BCM43602 firmware `7.35.177.56` does not answer `brcmfmac`'s `interface_create` version query. `patches/0002` lets `brcmf_cfg80211_request_ap_if()` fall through to its existing legacy `bsscfg:ssid` MBSS path so multiple AP SSIDs work.

## WPA3-SAE, OWE, DFS, and 802.11w (PMF)

- **WPA3-SAE, OWE, and DFS:** Unsupported by the 2015 `7.35.177.56` FullMAC firmware (`WIPHY_FLAG_HAVE_AP_SME` with neither `BRCMF_FEAT_SAE` nor `BRCMF_FEAT_SAE_EXT`). Use **WPA2-PSK (CCMP/AES)**.
- **802.11w (PMF) & 802.11k/v/r:** **Supported** by the `7.35.177.56` AP firmware (`-mfp-` built in). WPA2-PSK with PMF Optional (`ieee80211w=1`) is tested and works cleanly.

## SQM

`overlays/common/etc/hotplug.d/iface/32-dynamic-wan-sqm` creates a `cake` queue for the WAN zone but leaves it disabled with `0` kbit/s until configured:

```sh
uci set sqm.sqm_wan.download='91000'
uci set sqm.sqm_wan.upload='9000'
uci set sqm.sqm_wan.enabled='1'
uci commit sqm
/etc/init.d/sqm restart
```

## Radio watchdog

`radio-watchdog` (cron, every 5 minutes) watches for known `brcmfmac` firmware-wedge log signatures ([openwrt/openwrt#14685](https://github.com/openwrt/openwrt/issues/14685), [#20514](https://github.com/openwrt/openwrt/issues/20514)) and escalates from `wifi reload` to module reload to a rate-limited reboot (at most once per 6 hours). Disable it with `/etc/init.d/radio-watchdog disable` if undesired.

## `sysupgrade` backups

OpenWrt config-preserving upgrades can occasionally reset config files ([openwrt/openwrt#21655](https://github.com/openwrt/openwrt/issues/21655)). Always back up with `sysupgrade -b backup.tar.gz` before upgrading.
