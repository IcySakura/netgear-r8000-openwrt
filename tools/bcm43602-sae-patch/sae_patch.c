/*
 * BCM43602A1 (7.35.177.56) Cortex-R4 WPA3-SAE (sae_ext) Firmware Patch
 *
 * Implements host-offloaded WPA3-SAE AP support with zero data-plane overhead:
 *  - Incoming SAE Auth frames (auth_alg == 3) are intercepted in wlc_ap_authresp
 *    (ROM 0x34464 via 1 hardware TCAM slot) and forwarded to brcmfmac via
 *    WLC_E_AUTH_IND (event 4, auth_type = 3, raw 802.11 Auth frame payload).
 *  - Outgoing SAE Auth Commit/Confirm frames from hostapd arrive via the new
 *    "sae_tx" bsscfg iovar (extended into RAM mfp module), are transmitted over
 *    the hardware radio via wlc_frame_get_mgmt + wlc_sendctl, and on Confirm
 *    success (seq == 2, status == 0) mark the STA's SCB authenticated.
 *  - Custom WPA3 / WPA2-WPA3 Transition RSN IE (+ optional RSNXE) from hostapd
 *    is stored per-bsscfg via "sae_rsnie" and emitted in Beacons & ProbeResp
 *    by hooking RAM wlc_akm_build_rsn_ie (0x19ac9c).
 *  - Incoming AssocReq RSN IE with AKM 00-0F-AC:08 (SAE) is accepted by hooking
 *    RAM wlc_wpa_auth_parse_rsn_ie (0x19b024 / 0x19b05a) with SHA256 + 802.11w
 *    MFP enabled, leaving 4-way handshake and 100% hardware AES-CCMP + BIP
 *    offload completely intact.
 */
#include <stdint.h>
#include <stddef.h>

/* ROM / RAM function addresses (Thumb bit = 1 for indirect calls) */
typedef void *(*wlc_bsscfg_find_by_wlcif_fn)(void *wlc, void *wlcif);
typedef void  (*wlc_bss_mac_event_fn)(void *wlc, void *bsscfg, uint32_t msg,
				      const uint8_t *addr, uint32_t status,
				      uint32_t reason, uint32_t auth_type,
				      void *data, uint32_t datalen);
typedef void *(*wlc_frame_get_mgmt_fn)(void *wlc, uint16_t fc,
				       const uint8_t *da, const uint8_t *sa,
				       const uint8_t *bssid, uint32_t body_len,
				       uint8_t **pbody);
typedef int   (*wlc_sendctl_fn)(void *wlc, void *pkt, void *qi, void *scb,
				void *bsscfg, uint32_t rate_override,
				void *key, void *cb);
typedef void *(*wlc_scblookup_fn)(void *wlc, void *bsscfg, const uint8_t *ea);
typedef void  (*wlc_scb_set_auth_fn)(void *scb, int auth, int rssi, int band);
typedef int   (*wlc_wpa_akm2auth_fn)(const uint8_t *akm, uint16_t *auth_out, int flag);
typedef int   (*wlc_mfp_doiovar_fn)(void *ctx, const void *vi, uint32_t actionid,
				    const char *name, void *params, uint32_t plen,
				    void *arg, uint32_t alen, uint32_t vsize,
				    void *wlcif);
typedef uint8_t *(*wlc_akm_build_rsn_ie_fn)(void *wlc, void *bsscfg,
					    uint8_t *buf, int buflen);

#define fn_bsscfg_find  ((wlc_bsscfg_find_by_wlcif_fn)0x000452f1)
#define fn_bss_event    ((wlc_bss_mac_event_fn)0x00023065)
#define fn_get_mgmt     ((wlc_frame_get_mgmt_fn)0x000283fd)
#define fn_sendctl      ((wlc_sendctl_fn)0x0002ad99)
#define fn_scblookup    ((wlc_scblookup_fn)0x00072c0d)
#define fn_scb_set_auth ((wlc_scb_set_auth_fn)0x00072759)
#define fn_wpa_akm2auth ((wlc_wpa_akm2auth_fn)0x00188dc1)
#define fn_orig_mfp_iov ((wlc_mfp_doiovar_fn)0x001ad7e1)

/* Broadcom IOVAR descriptor (12 bytes) */
struct bcm_iovar {
	const char *name;
	uint16_t varid;
	uint16_t flags;
	uint16_t type;
	uint16_t minlen;
};

#define IOV_SVAL(id) ((id) * 2 + 1)
#define IOV_GVAL(id) ((id) * 2)
#define IOVT_BUFFER  8

#define MAX_SAE_BSS 8
#define MAX_RSNIE_LEN 80

struct sae_bss_entry {
	void *bsscfg;
	uint8_t len;
	uint8_t ie[MAX_RSNIE_LEN];
};

static struct sae_bss_entry sae_bss[MAX_SAE_BSS];

/* Replacement mfp_iovars table (pointed to by 0x1ed4f0) */
static const char str_sae_tx[]    = "sae_tx";
static const char str_sae_rsnie[] = "sae_rsnie";

__attribute__((used, section(".rodata.iovars")))
const struct bcm_iovar sae_mfp_iovars[5] = {
	{ (const char *)0x0009a9ec, 0, 0x0004, 0x0006, 0 },  /* "mfp" */
	{ (const char *)0x001d5550, 1, 0x0040, 0x0008, 0 },  /* "bip" */
	{ str_sae_tx,               2, 0x0000, IOVT_BUFFER, 0 },
	{ str_sae_rsnie,            3, 0x0000, IOVT_BUFFER, 0 },
	{ NULL, 0, 0, 0, 0 }
};

static void my_memcpy(void *dst, const void *src, uint32_t n)
{
	uint8_t *d = (uint8_t *)dst;
	const uint8_t *s = (const uint8_t *)src;
	while (n--)
		*d++ = *s++;
}

static struct sae_bss_entry *find_sae_entry(void *bsscfg, int alloc)
{
	int free_idx = -1;
	for (int i = 0; i < MAX_SAE_BSS; i++) {
		if (sae_bss[i].bsscfg == bsscfg)
			return &sae_bss[i];
		if (free_idx < 0 && sae_bss[i].bsscfg == NULL)
			free_idx = i;
	}
	if (alloc && free_idx >= 0) {
		sae_bss[free_idx].bsscfg = bsscfg;
		sae_bss[free_idx].len = 0;
		return &sae_bss[free_idx];
	}
	return NULL;
}

__attribute__((used))
static int sae_enabled_for_bss(void *bsscfg)
{
	struct sae_bss_entry *e = find_sae_entry(bsscfg, 0);
	return (e && e->len > 0);
}

/*
 * Hook 1: Incoming SAE Auth frame handler called from TCAM stub at ROM 0x34464.
 * Forwards full 802.11 Auth frame (24-byte hdr + body) via WLC_E_AUTH_IND (4)
 * with auth_type = 3 (WLAN_AUTH_SAE).
 */
__attribute__((used))
void sae_rx_auth_c(void *wlc, void *bsscfg, const uint8_t *hdr,
		   const uint8_t *body, uint32_t body_len)
{
	uint8_t frame[384];
	if (body_len < 6)
		return;
	if (body_len > sizeof(frame) - 24)
		body_len = sizeof(frame) - 24;
	my_memcpy(frame, hdr, 24);
	my_memcpy(frame + 24, body, body_len);
	/* WLC_E_AUTH_IND = 4, sa = hdr + 10, auth_type = 3 (SAE) */
	fn_bss_event(wlc, bsscfg, 4, hdr + 10, 0, 0, 3, frame, 24 + body_len);
}

/*
 * Assembly trampoline jumped to via TCAM slot 202 at ROM 0x34464:
 *   r4 = wlc, r5 = hdr, r6 = bsscfg, r8 = body, [sp + 456] = body_len
 * Original instruction at 0x34464: ldrh.w r2, [r8, #2] (4 bytes)
 * If *(uint16_t *)r8 == 3 (WLAN_AUTH_SAE), forward to host and exit via 0x346a4.
 */
__attribute__((naked, used))
void sae_authresp_trampoline(void)
{
	__asm__ volatile (
		"ldrh.w r2, [r8, #0]\n"          /* auth_alg */
		"cmp    r2, #3\n"                /* WLAN_AUTH_SAE? */
		"bne    1f\n"
		"ldr    r3, [sp, #456]\n"        /* body_len */
		"sub    sp, #8\n"
		"str    r3, [sp, #0]\n"          /* arg5: body_len */
		"mov    r0, r4\n"                /* arg1: wlc */
		"mov    r1, r6\n"                /* arg2: bsscfg */
		"mov    r2, r5\n"                /* arg3: hdr */
		"mov    r3, r8\n"                /* arg4: body */
		"bl     sae_rx_auth_c\n"
		"add    sp, #8\n"
		"ldr    pc, =0x000346a5\n"       /* clean wlc_ap_authresp exit */
	"1:\n"
		"ldrh.w r2, [r8, #2]\n"          /* original instr at 0x34464 */
		"ldr    pc, =0x00034469\n"       /* resume ROM at 0x34468 */
	);
}

/*
 * Hook 2: Extended mfp doiovar handler (pointed to by 0x1ed4ec).
 * Handles "sae_tx" (id=2) and "sae_rsnie" (id=3); forwards "mfp"/"bip" to stock.
 */
__attribute__((used))
int sae_mfp_doiovar(void *ctx, const void *vi, uint32_t actionid,
		    const char *name, void *params, uint32_t plen,
		    void *arg, uint32_t alen, uint32_t vsize, void *wlcif)
{
	void *wlc;
	void *bsscfg;

	if (actionid < 4)
		return fn_orig_mfp_iov(ctx, vi, actionid, name, params, plen,
				       arg, alen, vsize, wlcif);

	wlc = *(void **)ctx;
	bsscfg = fn_bsscfg_find(wlc, wlcif);
	if (!bsscfg)
		return -1;

	/* id=2: "sae_tx" (SET) — raw 802.11 Auth frame (24-byte hdr + body) */
	if (actionid == IOV_SVAL(2)) {
		const uint8_t *frame = (const uint8_t *)arg;
		if (!frame || alen < 30 || alen > 512)
			return -2; /* BCME_BADARG */

		const uint8_t *da = frame + 4;
		const uint8_t *sa = (const uint8_t *)bsscfg + 222;    /* cur_etheraddr */
		const uint8_t *bssid = (const uint8_t *)bsscfg + 216; /* BSSID */
		const uint8_t *body = frame + 24;
		uint32_t body_len = alen - 24;
		uint16_t auth_seq = (uint16_t)body[2] | ((uint16_t)body[3] << 8);
		uint16_t auth_status = (uint16_t)body[4] | ((uint16_t)body[5] << 8);

		/* Lookup/create SCB; on SAE Confirm success mark SCB authenticated */
		void *scb = fn_scblookup(wlc, bsscfg, da);
		if (scb && auth_seq == 2 && auth_status == 0) {
			int8_t bss_idx = *((const int8_t *)bsscfg + 68);
			fn_scb_set_auth(scb, 1, bss_idx, 0);
		}

		uint8_t *pbody = NULL;
		void *pkt = fn_get_mgmt(wlc, 0x00b0, da, sa, bssid, body_len, &pbody);
		if (!pkt || !pbody)
			return -3; /* BCME_NOMEM */

		my_memcpy(pbody, body, body_len);

		/* qi = bsscfg->enable ? bsscfg->wlcif->qi : wlc->active_queue */
		uint8_t bss_en = *((const uint8_t *)bsscfg + 6);
		void *qi;
		if (bss_en) {
			void *cfg_wlcif = *(void **)((const uint8_t *)bsscfg + 12);
			qi = *(void **)((const uint8_t *)cfg_wlcif + 12);
		} else {
			qi = *(void **)((const uint8_t *)wlc + 0x5e4);
		}
		fn_sendctl(wlc, pkt, qi, scb, bsscfg, 0, NULL, NULL);
		return 0;
	}

	/* id=3: "sae_rsnie" (SET/GET) — per-bsscfg RSN IE (+ optional RSNXE) */
	if (actionid == IOV_SVAL(3)) {
		if (alen > MAX_RSNIE_LEN)
			return -2;
		int clear = (alen == 0) || (alen == 1 && ((const uint8_t *)arg)[0] == 0);
		struct sae_bss_entry *e = find_sae_entry(bsscfg, !clear);
		if (!e)
			return clear ? 0 : -3;
		if (clear) {
			e->bsscfg = NULL;
			e->len = 0;
		} else {
			my_memcpy(e->ie, arg, alen);
			e->len = (uint8_t)alen;
		}
		return 0;
	}
	if (actionid == IOV_GVAL(3)) {
		struct sae_bss_entry *e = find_sae_entry(bsscfg, 0);
		uint8_t len = e ? e->len : 0;
		if (alen < len)
			return -4;
		if (len > 0)
			my_memcpy(arg, e->ie, len);
		return 0;
	}

	return -23; /* BCME_UNSUPPORTED */
}

/*
 * Hook 3: RAM wlc_akm_build_rsn_ie (0x19ac9c).
 * If custom sae_rsnie is configured for this bsscfg, emit it directly;
 * otherwise fall through to stock 0x19aca0.
 */
__attribute__((used))
uint8_t *sae_build_rsn_ie_c(void *bsscfg, uint8_t *buf, int buflen)
{
	struct sae_bss_entry *e = find_sae_entry(bsscfg, 0);
	if (!e || e->len == 0)
		return NULL;
	if (buflen < (int)e->len)
		return buf;
	my_memcpy(buf, e->ie, e->len);
	return buf + e->len;
}

/*
 * Replaced at RAM 0x19ac9c (original 4 bytes: e92d 4ff0 = push {r4-r11, lr})
 */
__attribute__((naked, used))
void sae_build_rsn_ie_trampoline(void)
{
	__asm__ volatile (
		"push   {r0-r3, lr}\n"
		"mov    r0, r1\n"       /* bsscfg */
		"mov    r1, r2\n"       /* buf */
		"mov    r2, r3\n"       /* buflen */
		"bl     sae_build_rsn_ie_c\n"
		"cbz    r0, 1f\n"
		"add    sp, #16\n"      /* discard saved r0-r3 */
		"pop    {pc}\n"         /* return buf + len */
	"1:\n"
		"pop    {r0-r3, lr}\n"
		"stmdb  sp!, {r4, r5, r6, r7, r8, r9, sl, fp, lr}\n" /* orig @ 0x19ac9c */
		"ldr    pc, =0x0019aca1\n"
	);
}

/*
 * Hook 4a: RAM wlc_wpa_auth_parse_rsn_ie (0x19b024, 4 bytes: cmp r3, #2; bne 0x19b09e).
 * Accept AKM 8 (SAE) when sae_rsnie is enabled on bsscfg (r6), remapping r3 = 6 (PSK-SHA256)
 * so firmware enforces MFP and sets SCB_SHA256.
 */
__attribute__((naked, used))
void sae_parse_akm_trampoline(void)
{
	__asm__ volatile (
		"cmp    r3, #2\n"
		"beq    2f\n"           /* stock WPA2-PSK */
		"cmp    r3, #8\n"       /* SAE AKM? */
		"bne    3f\n"           /* reject */
		"push   {r0-r3, lr}\n"
		"mov    r0, r6\n"       /* bsscfg */
		"bl     sae_enabled_for_bss\n"
		"cmp    r0, #0\n"
		"pop    {r0-r3, lr}\n"
		"beq    3f\n"           /* reject if SAE not enabled on this BSS */
		"movs   r3, #6\n"       /* map SAE -> PSK-SHA256 for MFP/SHA256 checks */
	"2:\n"
		"ldr    pc, =0x0019b029\n"
	"3:\n"
		"ldr    pc, =0x0019b09f\n"
	);
}

/*
 * Hook 4b: Called via BL replacement at RAM 0x19b05a (wlc_wpa_akm2auth).
 * Maps AKM type 8 -> 6 in a temporary 4-byte copy so incoming AssocReq IE is untouched.
 */
__attribute__((used))
int sae_wpa_akm2auth_hook(const uint8_t *akm, uint16_t *auth_out, int flag)
{
	if (akm[3] == 8) {
		uint8_t tmp[4] = { akm[0], akm[1], akm[2], 6 };
		return fn_wpa_akm2auth(tmp, auth_out, flag);
	}
	return fn_wpa_akm2auth(akm, auth_out, flag);
}
