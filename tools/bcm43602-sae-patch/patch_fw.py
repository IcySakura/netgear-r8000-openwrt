#!/usr/bin/env python3
"""
BCM43602A1 (7.35.177.56) Cortex-R4 WPA3-SAE Firmware Patcher.
Relocates the 202-entry TCAM descriptor table into a heap-protected 8 KB
extension (0x211610..0x213508), injects our compiled Thumb-2 C patch at
0x212300, and wires:
  - TCAM slot 202 @ ROM 0x034464 -> sae_authresp_trampoline
  - RAM 0x1ed4ec -> sae_mfp_doiovar | 1 (mfp/bip/sae_tx/sae_rsnie)
  - RAM 0x1ed4f0 -> sae_mfp_iovars
  - RAM 0x19ac9c -> b.w sae_build_rsn_ie_trampoline
  - RAM 0x19b024 -> b.w sae_parse_akm_trampoline
  - RAM 0x19b05a -> bl  sae_wpa_akm2auth_hook
"""
import struct
import subprocess
import sys

BASE = 0x180000
OLD_ARENA_START = 0x211508
NEW_ARENA_START = 0x213508
NEW_TCAM_TABLE  = 0x211700
CUSTOM_CODE_ORG = 0x212300

OLD_TCAM_START = 0x181800
OLD_TCAM_END   = 0x182178
OLD_TCAM_COUNT = 202
FREE_POOL_BASE = 0x181650

TCAM_START_REFS = [0x1de35c, 0x1de3ac, 0x1de4c8, 0x1de5e0]
TCAM_END_REFS   = [0x1de358, 0x1de3b0, 0x1de4c4, 0x1de5dc]
ARENA_START_REF = 0x1ddfec


def _encode_thumb2_branch(pc: int, target: int, link: bool) -> bytes:
    offset = target - (pc + 4)
    assert -16777216 <= offset <= 16777214 and (offset & 1) == 0, f"branch out of range: {offset:#x}"
    imm = offset >> 1
    S = (imm >> 23) & 1
    I1 = (imm >> 22) & 1
    I2 = (imm >> 21) & 1
    J1 = (~I1 ^ S) & 1
    J2 = (~I2 ^ S) & 1
    imm10 = (imm >> 11) & 0x3ff
    imm11 = imm & 0x7ff
    hw1 = 0xF000 | (S << 10) | imm10
    hw2 = (0xD000 if link else 0x9000) | (J1 << 13) | (J2 << 11) | imm11
    return struct.pack('<HH', hw1, hw2)


def encode_thumb2_bw(pc: int, target: int) -> bytes:
    return _encode_thumb2_branch(pc, target, link=False)


def encode_thumb2_bl(pc: int, target: int) -> bytes:
    return _encode_thumb2_branch(pc, target, link=True)


def load_symbols(nm_bin: str, elf_path: str) -> dict:
    out = subprocess.check_output([nm_bin, elf_path], text=True)
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
    return syms


def patch_firmware(in_path: str, out_path: str, extra_tcam, custom_code: bytes, ram_patches):
    fw = bytearray(open(in_path, 'rb').read())
    assert len(fw) == 0x91610, f"Unexpected firmware size {len(fw):#x}"
    trailer = bytes(fw[0x91508:0x91610])

    assert struct.unpack_from('<I', fw, ARENA_START_REF - BASE)[0] == OLD_ARENA_START
    for ref in TCAM_START_REFS:
        assert struct.unpack_from('<I', fw, ref - BASE)[0] == OLD_TCAM_START
    for ref in TCAM_END_REFS:
        assert struct.unpack_from('<I', fw, ref - BASE)[0] == OLD_TCAM_END

    orig_descs = fw[OLD_TCAM_START - BASE : OLD_TCAM_END - BASE]

    new_len = (NEW_ARENA_START - BASE) + len(trailer)
    fw.extend(b'\x00' * (new_len - len(fw)))
    fw[NEW_ARENA_START - BASE : NEW_ARENA_START - BASE + len(trailer)] = trailer
    struct.pack_into('<I', fw, ARENA_START_REF - BASE, NEW_ARENA_START)

    fw[NEW_TCAM_TABLE - BASE : NEW_TCAM_TABLE - BASE + len(orig_descs)] = orig_descs
    tcam_count = OLD_TCAM_COUNT

    for idx, (rom_addr, target_addr) in enumerate(extra_tcam):
        assert (rom_addr & 3) == 0, f"TCAM ROM addr must be 4-byte aligned: {rom_addr:#x}"
        slot = OLD_TCAM_COUNT + idx
        assert slot < 256
        pool_addr = FREE_POOL_BASE + idx * 8
        bw = encode_thumb2_bw(rom_addr, target_addr)
        fw[pool_addr - BASE : pool_addr - BASE + 4] = bw
        fw[pool_addr - BASE + 4 : pool_addr - BASE + 8] = b'\x00\x00\x00\x00'
        desc_off = (NEW_TCAM_TABLE - BASE) + slot * 12
        struct.pack_into('<3I', fw, desc_off, rom_addr, 4, pool_addr)
        tcam_count += 1

    new_tcam_end = NEW_TCAM_TABLE + tcam_count * 12
    for ref in TCAM_START_REFS:
        struct.pack_into('<I', fw, ref - BASE, NEW_TCAM_TABLE)
    for ref in TCAM_END_REFS:
        struct.pack_into('<I', fw, ref - BASE, new_tcam_end)

    assert CUSTOM_CODE_ORG + len(custom_code) <= NEW_ARENA_START
    fw[CUSTOM_CODE_ORG - BASE : CUSTOM_CODE_ORG - BASE + len(custom_code)] = custom_code

    for addr, data in ram_patches:
        fw[addr - BASE : addr - BASE + len(data)] = data

    open(out_path, 'wb').write(fw)
    print(f"Wrote SAE-patched firmware: {out_path} ({len(fw)} bytes, TCAM={tcam_count}/256, code={len(custom_code)}B)")


if __name__ == '__main__':
    in_fw, elf_path, bin_path, nm_bin, out_fw = sys.argv[1:6]
    syms = load_symbols(nm_bin, elf_path)
    code = open(bin_path, 'rb').read()

    extra_tcam = [
        (0x034464, syms['sae_authresp_trampoline']),
    ]
    ram_patches = [
        (0x1ed4ec, struct.pack('<I', syms['sae_mfp_doiovar'] | 1)),
        (0x1ed4f0, struct.pack('<I', syms['sae_mfp_iovars'])),
        (0x19ac9c, encode_thumb2_bw(0x19ac9c, syms['sae_build_rsn_ie_trampoline'])),
        (0x19b024, encode_thumb2_bw(0x19b024, syms['sae_parse_akm_trampoline'])),
        (0x19b05a, encode_thumb2_bl(0x19b05a, syms['sae_wpa_akm2auth_hook'])),
    ]
    patch_firmware(in_fw, out_fw, extra_tcam, code, ram_patches)
