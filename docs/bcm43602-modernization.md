# BCM43602 Cortex-R4 Modernization (`patches/0005` & `tools/bcm43602-sae-patch`)

Each Netgear R8000 radio is a **Broadcom BCM43602A1** FullMAC PCIe SoC running an embedded ARM Cortex-R4 (`7.35.177.56`, 640 KB Mask ROM + 960 KB TCM RAM, 256 hardware TCAM ROM-patch slots).

## Hardware-Offloaded Driver Features (`patches/0005`)

All features below execute inside the BCM43602 Cortex-R4 / PHY with zero host data-plane CPU overhead:

- **Live Airtime & Noise Survey (`chanim_stats` v2 → `dump_survey`):** Exposes non-disruptive (~0.1 ms, zero channel switch) monotonic active/busy/rx/tx airtime and noise floor (`dBm`) to `iw survey dump`, `iwinfo`, LuCI, and `unifi-openwrt` airtime/interference graphs.
- **2.4 GHz Explicit Beamforming + 256-QAM TurboQAM:** Sets `txbf_ht_enable=1` and `vht_features=3` during init (+33% 2.4 GHz 3×3 PHY ceiling, 450 → 600 Mbit/s).
- **Cortex-R4 Hardware Airtime Fairness (`taf`):** Enables firmware-side TX airtime scheduling (`taf enable 1`) so slow or distant clients cannot starve fast clients.
- **802.11e QBSS Load IE (`bssload=1`):** Broadcasts live station count and airtime utilization in beacons for improved client roaming and band-steering decisions.
- **Hardware-Offloaded DFS (`wlc_dfs` + `phy_radar`):** Advertises `radar_detect_widths` alongside `NL80211_EXT_FEATURE_DFS_OFFLOAD` and arms `WLC_SET_SPECT_MANAGMENT` (`244`) + `WLC_SET_RADAR` (`243`) when starting an AP on a DFS channel.
  - Verified live on 5 GHz Low (ch 52, 5260 MHz): full 60-second silent CAC (`state=1`, 0% TX) → In-Service Monitoring (`state=2`) → instant radar vacate via CSA (`state=3`) on simulated radar hit.
  - Note: OpenWrt's R8000 DTS maps `US` to Broadcom's non-DFS `Q2/86` CLM profile (reflecting the original 2014 US FCC certification); regulatory domains whose CLM profile includes DFS (such as `DE`/`GB`) expose DFS channels automatically on the 5 GHz Low radio (`5170–5730 MHz`).

## Source-Built Cortex-R4 WPA3-SAE Patch (`tools/bcm43602-sae-patch`)

Stock `7.35.177.56` predates WPA3-SAE (`auth_alg=3`, AKM `00-0F-AC:08`), though it already includes hardware AES-CCMP and 802.11w PMF (BIP-CMAC-128). Because BCM43602A1 has **54 unused hardware TCAM ROM-patch slots** (`202/256` used), `scripts/build.sh` compiles `sae_patch.c` from source using OpenWrt's ARM GCC toolchain (`-mcpu=cortex-r4 -mthumb`) and patches upstream `brcmfmac43602-pcie.bin` at build time (no binary blobs stored in git):

- **TCAM slot 202 (`ROM 0x034464`, `wlc_ap_authresp`):** Intercepts incoming SAE Authentication frames (`auth_alg=3`) and relays the raw 802.11 Auth frame to `brcmfmac` → `hostapd` via `WLC_E_AUTH_IND`.
- **`sae_tx` iovar (extended into RAM `mfp` module):** Transmits `hostapd`'s Dragonfly Commit/Confirm replies via `wlc_frame_get_mgmt` + `wlc_sendctl` and marks the STA's SCB authenticated on Confirm success (multi-SSID `bsscfg` aware).
- **`sae_rsnie` iovar (`RAM 0x19ac9c`, `wlc_akm_build_rsn_ie`):** Emits `hostapd`'s exact WPA3-SAE or WPA2/WPA3 Transition RSN IE (plus RSNXE `0x20` for SAE H2E) in beacons and probe responses.
- **AssocReq AKM-8 hook (`RAM 0x19b024` / `0x19b05a`, `wlc_wpa_auth_parse_rsn_ie`):** Accepts AKM `8` with SHA256 + 802.11w MFP, after which the standard 4-way handshake and **100% hardware AES-CCMP + BIP encryption** take over with zero data-plane CPU penalty.
- `brcmfmac` auto-detects `sae_rsnie` at probe time and advertises `NL80211_FEATURE_SAE` only when the patched firmware is loaded.
