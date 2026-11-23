# Adopting this router into a UniFi controller

This build's end goal is turning the R8000 into an access point your UniFi
controller can adopt, using [antoniocosta/unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt).
That project ships its **own** apk/installer rather than an OpenWrt feed
package (its build tooling is `tools/build.sh`/`tools/mkapk.sh`, producing a
static Go binary packaged outside OpenWrt's package buildroot conventions),
so it is not something `scripts/profile.sh`'s `CONFIG_PACKAGE_x=y` mechanism
can select and verify the way every other package in this repository is
checked. Writing a from-scratch OpenWrt package Makefile that cross-compiles
it from source, without being able to build-test that Makefile in this
environment, would be exactly the kind of unverified, speculative component
this repository tries to avoid (see the README's "What's verified" section).

So the division of labor here is: **this image carries every real OpenWrt
package unifi-openwrt needs, preinstalled; installing unifi-openwrt itself is
one more step after first boot, following its own upstream README exactly.**

## What this image already has

From `configs/r8000.config` and `configs/base.packages` (every profile except
`minimal` - see `profiles/minimal.packages` if you removed them):

| Requirement (per unifi-openwrt's README) | Provided by |
|---|---|
| Full `wpad` (802.11k/v, SAE where supported), not `wpad-basic-*` | `wpad-openssl` (`wpad-basic-mbedtls` explicitly excluded) |
| `hostapd-utils` (its runtime client deny list) | included |
| `kmod-nft-bridge` (guest-network isolation) | included |
| `kmod-veth` (fast roaming) | included |
| Wi-Fi radios enabled | **not** done for you - a fresh OpenWrt install ships radios disabled; see below |

Flash is not a constraint here: the R8000 has 128 MB of NAND flash and an
OpenWrt base image around 9 MB, and unifi-openwrt's own binary is on the
order of 8-10 MB - comfortably inside the ~16 MB-and-up devices its README
says are fine (it specifically warns about 16 MB *total*-flash devices, which
this is not).

## What is genuinely unverified

Nobody - as far as this investigation found - has run unifi-openwrt on an
R8000, or on any bcm53xx/`brcmfmac` device at all. Its "Tested devices" table
is all `mt76`/`mwl8k`/`ath12k` hardware. Its README's only driver-specific
caveats are for `mwl8k` and `ath12k`; `brcmfmac` is not mentioned either way.
That is a reasonable "should work" rather than a confirmed one - the usual
class of risk with brcmfmac on this board is a firmware wedge under load
(see `docs/known-issues.md`), not something specific to unifi-openwrt's own
adoption/management protocol.

## Steps, after flashing this firmware

1. **Enable the radios and set a LAN password** first, as with any fresh
   OpenWrt install:
   ```sh
   uci set wireless.radio0.disabled=0
   uci set wireless.radio1.disabled=0
   uci set wireless.radio2.disabled=0
   uci commit wireless
   wifi reload
   passwd   # set a root password before exposing this to your network
   ```
2. **Get unifi-openwrt onto the router.** Follow its own README, either path:
   - **apk (OpenWrt 25.12+, matches this build):** build or download the
     `.apk` matching your router's architecture (`cat /etc/apk/arch` on the
     router; the R8000 is `armv7`), copy it over, then:
     ```sh
     apk add --allow-untrusted ./unifi-openwrt_*.apk
     ```
   - **install.sh (works on opkg-based OpenWrt too):** copy `dist/openwrt/`
     from the unifi-openwrt repository to the router and run `sh install.sh`
     - it checks free flash and pulls in anything still missing itself.
3. **Point it at your controller** (`/etc/config/unifi-openwrt`, or `uci`):
   ```sh
   uci set unifi-openwrt.main.model='U7PG2'
   uci set unifi-openwrt.main.inform_url='http://<controller-ip>:8080/inform'
   uci set unifi-openwrt.main.apply='0'
   uci set unifi-openwrt.main.enabled='1'
   uci commit unifi-openwrt
   /etc/init.d/unifi-openwrt enable
   /etc/init.d/unifi-openwrt start
   ```
   Use an **IP address** for `inform_url`, not a hostname - the project's own
   README stresses this; the AP cannot always resolve a hostname that early.
   `model` is a UniFi model string it presents to the controller (e.g.
   `U7PG2`); pick one your controller version recognises as a supported AP
   model, since the controller's UI and feature set depend on it.
4. **Adopt it.** The AP should appear in your UniFi controller as "pending
   adoption" - adopt it there as you would any other AP. unifi-openwrt's own
   safety net (an automatic rollback ~5 minutes after an unconfirmed `apply`,
   and it never applies a real Ubiquiti firmware image even if the controller
   offers one) is documented in its README; read it before changing
   `unifi-openwrt.main.apply` to `1`.
5. Other tunables worth knowing about (all in `/etc/config/unifi-openwrt`,
   see the upstream README for the full list): `hostname`, `profile_caps`,
   `locate_beep`, `mesh_uplink`, `ssh_port` (default 2222 - the port your
   controller uses to reach the AP, distinct from the router's own SSH),
   `hw_caps`, `inform_every`, `led_idle`, `uplink_port`, `console`,
   `ft_relay`, `ft_verbose`.

If adoption or Wi-Fi behaves oddly, check `docs/known-issues.md` first - the
radio watchdog this image ships logs under the `radio-watchdog` tag and is a
more likely explanation than unifi-openwrt itself for a radio dropping out
under load.
