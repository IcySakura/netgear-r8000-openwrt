# UniFi Controller Adoption (`unifi-openwrt`)

This firmware includes all OpenWrt-side dependencies required by [antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt) (`wpad-openssl`, `hostapd-utils`, `kmod-nft-bridge`, `kmod-veth`). The agent itself is installed after flashing.

## Architecture note (softfloat)

The R8000's BCM4709A0 has **no hardware FPU** (`arm_cortex-a9` softfloat). Build or install a **`GOARM=7,softfloat`** binary — upstream `arm_cortex-a9_vfpv3-d16` packages will fail with `SIGILL`.

## Setup

1. **Install the softfloat `.apk`:**
   ```sh
   apk add --allow-untrusted ./unifi-openwrt_*_arm_cortex-a9.apk
   ```
2. **Switch to Dumb AP mode** (bridge `lan1`–`lan4` + `wan` on `br-lan` with `proto='dhcp'`, disable `dnsmasq`/`odhcpd`) so the AP reports its LAN IP to the controller.
3. **Enable all 3 radios** before adoption so `unifi-openwrt` reports all 3 phys cleanly.
4. **Configure `unifi-openwrt`** (recommended model `UHDIW` for 4 LAN ports + 1 uplink):
   ```sh
   uci set unifi-openwrt.main.model='UHDIW'
   uci set unifi-openwrt.main.hostname='Netgear-R8000'
   uci set unifi-openwrt.main.inform_url='http://<controller-ip>:8080/inform'
   uci set unifi-openwrt.main.uplink_port='wan'
   uci set unifi-openwrt.main.ft_relay='1'
   uci set unifi-openwrt.main.apply='1'
   uci set unifi-openwrt.main.enabled='1'
   uci commit unifi-openwrt
   /etc/init.d/unifi-openwrt enable
   /etc/init.d/unifi-openwrt restart
   ```
5. **Adopt** the AP in your UniFi controller UI.

## Controller Wi-Fi notes

- Use **WPA2-PSK (AES/CCMP)** with optional **PMF (802.11w)** and **802.11r Fast Roaming** — avoid WPA3-SAE (unsupported by BCM43602 firmware; see [docs/known-issues.md](known-issues.md)).
- Keep the two 5 GHz radios within their hardware filter bands (**Low: ch 36–48**, **High: ch 149–165**).
