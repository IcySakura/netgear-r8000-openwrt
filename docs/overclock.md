# CPU overclocking: investigated, not implemented

> [!IMPORTANT]
> **Correction, 2026-11-24, from the real device's own bootloader.** The
> sections below say the CFE `clkfreq` variable is interpreted only by
> DD-WRT/Tomato's own Linux board code and that OpenWrt has no way to use
> it. That is wrong. `clkfreq` is read **by CFE itself**, before any kernel
> runs, so it applies under OpenWrt exactly as under stock or DD-WRT. What
> remains true: Linux has no runtime cpufreq/`set_rate` path for this SoC,
> and there is no software voltage control. See
> [What the R8000's own CFE does](#what-the-r8000s-own-cfe-does-2026-11-24)
> at the end for the evidence and for the prepared (not executed) procedure.

Short version: **this build does not include an overclock option.** Unlike
the other two repositories this one follows the conventions of (both of
which ship a real, reversible overclock feature for their own SoCs - see
their `docs/cpu-overclock.md`), there is nothing for a comparable feature on
the R8000 to attach to. This was first investigated when this repository was
written, and re-investigated from scratch on 2026-11-22 against mainline
Linux itself (not just OpenWrt's tree, and not taking the earlier conclusion
at face value) after studying exactly how
[linksys-mx4300-openwrt-nss](https://github.com/IcySakura/linksys-mx4300-openwrt-nss)
achieves overclocking on its Qualcomm IPQ807x SoC, to see whether an
analogous mechanism exists here. It does not - see below for the evidence and
exactly why the MX4300's trick does not transfer.

## The MX4300 pattern, for comparison

The MX4300's overclock (`docs/cpu-overclock.md` in that repository) does not
reprogram the CPU's own PLL past its design limit. Instead it exploits three
facts specific to that SoC:

1. The CPU cluster's own PLL (APSS "Huayra") is hard-clamped in hardware at
   1401.6 MHz regardless of what is programmed into it.
2. The CPU clock mux can *already* select a second, independent PLL
   (`GPLL2`) that the SoC's global clock controller exposes for an unrelated
   purpose (SD/eMMC), which has no such clamp and is not used by anything on
   that board.
3. A kernel patch (`apss-ipq6018.c`) teaches the existing clock-mux driver to
   take rates above the clamp from that second PLL when the device tree
   names it, parks the cores on a third, always-safe PLL during every rate
   change, and exposes the new rates as ordinary `operating-points-v2` boost
   entries. Voltage is handled by the SoC's existing closed-loop CPR
   regulator, extended with a runtime debugfs offset.

The common thread: **every piece this needs (the alternate PLL, the mux that
can already select it, the clock-rate-change notifier mechanism, the OPP/CPR
voltage-scaling infrastructure) already exists upstream for this SoC
family and is already active in Linux.** The MX4300 patch is additive glue
between parts the kernel/DT already have, not an attempt to make silicon do
something nobody has gotten it to do.

That is the bar this document tried to find an equivalent for on BCM4709A0.

## What was re-checked on 2026-11-22, directly against mainline Linux

Earlier docs here had checked OpenWrt's own `target/linux/bcm53xx/` tree
(patches, kernel config, base-files) and found no "cpufreq" anywhere. That
alone does not rule out "exists upstream, just not wired up by OpenWrt" - so
this pass went to mainline Linux source directly
(`git.kernel.org/.../torvalds/linux.git`, current `master`) instead of taking
that absence as final:

- **`drivers/cpufreq/` has no Northstar/iProc/bcm5301x/BCM4708-4709 driver.**
  The full directory listing (85 files) has exactly two Broadcom-named
  drivers: `brcmstb-avs-cpufreq.c` (Broadcom's **set-top-box** BCM7xxx ARM
  family, a different SoC line entirely, driven by a separate AVS firmware
  co-processor) and `bmips-cpufreq.c` (Broadcom's **MIPS**-based BCM63xx/3368
  line, not this ARM Cortex-A9 family at all). Nothing else Broadcom-related
  exists in that directory, in any kernel version.
- **`arch/arm/mach-bcm/bcm_5301x.c`** (the platform code `DT_MACHINE_START`
  for `brcm,bcm4708`, which is what the R8000 and every BCM4709 board
  matches) registers only an early abort-handler quirk for PCIe. No power
  management, no `cpufreq` registration, no `.pm` hook at all. The sibling
  `bcm_nsp.c` (for `brcm,nsp`, the closely related NSP line) is even
  shorter. Neither file has ever had cpufreq-related code.
- **The ARM PLL clock driver's own `clk_ops` table has no write path.**
  `drivers/clk/bcm/clk-iproc-armpll.c` (`iproc_armpll_setup()`, the function
  the earlier pass correctly identified as backing the `a9pll` node) defines:
  ```c
  static const struct clk_ops iproc_arm_pll_ops = {
          .recalc_rate = iproc_arm_pll_recalc_rate,
  };
  ```
  That is the **entire** ops table - `recalc_rate` only (read the current
  hardware state back into the clock framework). There is no `.set_rate`,
  `.round_rate`, or `.determine_rate`. This is not "present but unused by
  OpenWrt" - the upstream Linux driver for this exact clock is architecturally
  read-only, on every kernel version that has ever shipped it, for every
  SoC that uses `brcm,nsp-armpll` (the BCM5301x/Northstar family, including
  the R8000's BCM4709A0).
- **The hardware register layout this read-only code exposes is more
  interesting than "nothing is there," though.** `iproc_arm_pll_recalc_rate()`
  decodes a genuine frequency-ID (FID) policy mechanism: a register
  (`ARM_DIV` at offset `0xe00`) holds a 4-entry "policy" select with an
  override bit, each policy slot pointing (via `POLICY_FREQ` at `0x008`) at
  one of four FIDs - crystal clock, system clock, PLL channel 0 ("slow"), or
  PLL channel 1 ("fast") - and the PLL's own dividers
  (`PLLARMA`/`PLLARMB`/`PLLARMC` at `0xc00`-`0xc08`, holding `pdiv`, a
  20-bit fixed-point `ndiv`, and `mdiv`) are fully programmable in principle,
  including a documented "offset mode" (`PLLARM_OFFSET` at `0xc24`, a
  `SW_CTL` bit that substitutes a software-supplied `ndiv` for the normal
  one). **Nothing in mainline Linux, OpenWrt, or (as far as this
  investigation found) any public DD-WRT/Tomato/vendor GPL source ever
  writes to this register set at runtime.** The closest known analogue - the
  CFE bootloader's NVRAM `clkfreq` variable DD-WRT/Tomato use on this SoC
  family - is read by *those vendor firmwares' own early board-init code*
  before Linux proper starts, not by CFE itself and not by anything in
  mainline Linux; OpenWrt's boot path for this device does not read or
  interpret that variable at all (re-confirmed: no match for `clkfreq` or
  `armpll` anywhere in OpenWrt's pinned `openwrt-25.12` `target/linux/bcm53xx/`
  tree).
- **OpenWrt's generic kernel config explicitly disables `CONFIG_CPU_FREQ`**
  (`target/linux/generic/config-6.12`: `# CONFIG_CPU_FREQ is not set`, plus
  every `CPU_FREQ_*` governor option), and the `bcm53xx`-specific
  `config-6.12` does not re-enable it. So even if a driver existed, this
  target's kernel is not currently built with the cpufreq subsystem at all -
  a second, independent reason `/sys/devices/system/cpu/cpufreq/` does not
  exist on this build, on top of there being no driver to populate it.

**Verdict, re-confirmed with primary sources this time (exact files,
functions and register offsets, not just an absence of a grep match): there
is no OS-level dynamic frequency scaling mechanism for this SoC anywhere in
mainline Linux, let alone in OpenWrt.** This is a stronger, better-evidenced
version of the same conclusion the first pass reached - not a reversal of it.

## Why the MX4300 pattern does not transfer

Mapping the MX4300's three ingredients onto BCM4709A0:

| MX4300 (IPQ8174) | BCM4709A0 (Northstar) |
|---|---|
| CPU PLL hard-clamped in hardware, but reads back cleanly | CPU PLL (`a9pll`) has no clamp *known* to exist, but also has no documented, verified-safe way to reprogram its dividers live while cores are clocked from it |
| A second, already-active PLL (`GPLL2`) is one mux-select away, already running, already stable at the target rates for an unrelated peripheral | The nearest analogue (the FID "policy" mechanism) is real hardware but has **no known-safe write sequence published anywhere** - not upstream, not in any community project, not in any vendor GPL source this investigation found. Nobody has published what happens if you flip `SW_CTL` or write a new `ndiv` while the cores are live. |
| The clock-rate-change notifier mechanism (`cpu_clk_notifier_fn`, parking cores on a safe third clock during any PLL change) already exists in the upstream Qualcomm clock driver for exactly this purpose | No equivalent notifier/parking mechanism exists for `a9pll` in `clk-iproc-armpll.c` - adding one means writing it from scratch against a register interface nobody has validated for runtime changes |
| Voltage scaling piggybacks on the SoC's existing closed-loop CPR regulator, already modeled in the kernel, with corner tables already calibrated by Qualcomm per speed bin | There is no equivalent software-visible voltage-control path for this SoC documented anywhere; voltage for this family is set by board-level regulators/straps at hardware design time, not adjusted by Linux |

Every row on the MX4300 side is "a thing that already works, glued
together." Every row on the BCM4709A0 side is "would need to be invented and
validated on real silicon, with no published prior art to build from and no
`operating-points-v2`/CPR-equivalent safety net to fall back into if it goes
wrong." That is a different category of work, not a smaller version of the
same work.

## What it would actually take

Either of:

1. A new kernel clock driver (not a config toggle) that adds `.set_rate` to
   `iproc_arm_pll_recalc_rate`'s ops table, writes `PLLARMA`/`B`/`C` and/or
   the `ARM_DIV` policy override directly, and - critically - parks the CPU
   cores on a safe clock source during the transition the way the MX4300
   patch's notifier does, since nothing here currently does that and the ARM
   PLL is the cores' *only* known clock source today (there is no GPLL2-style
   escape hatch already wired to this mux in any Northstar devicetree found).
   This is genuine kernel driver development against an undocumented-for-this-
   purpose register interface, on hardware this repository cannot test on.
2. Reverse-engineering and reimplementing the DD-WRT/Tomato-era CFE
   `clkfreq` early-boot mechanism *inside OpenWrt's own boot path* (it is not
   CFE itself that interprets `clkfreq` - that logic lives in those vendor
   Linux builds' own board-init code, which OpenWrt does not carry). This is
   not "turn on a flag CFE already understands" - it would mean writing new
   early-boot code for OpenWrt's kernel that does not exist today, calling
   into the same unverified PLL registers as option 1 anyway.

Both are real, from-scratch kernel engineering against a chip whose runtime
voltage/frequency-margin characteristics are not documented for OpenWrt's use
case, not something to ship as a default-off "config option" per the user's
framing - because unlike the MX4300, there is no existing on/off switch
anywhere in this stack to wrap. Shipping either, untested, as "experimental"
would be exactly the kind of self-written, unvalidated low-level change this
repository avoids elsewhere (see `docs/ctf-fa.md` for the same reasoning
applied to hardware packet offload, including why that one *did* get an
experimental branch and this one does not: FA has an existing, reviewed,
measured-on-real-hardware upstream patch set to build the R8000-specific
piece on top of; CPU overclocking on this SoC has no comparable foundation
to stand on anywhere, for anyone, on any BCM4709-family board).

## What was found about overclocking this SoC family (context, not OpenWrt)

No R8000-specific overclock thread was found (the OpenWrt forum archive
thread referenced in community discussion, and the DD-WRT wiki's
overclocking page, both returned bot-protection "Access Denied" pages to
every fetch attempt, in both the original and this pass, and could not be
read). What follows is for the closely related **R7000** (same BCM4709A0
SoC, via CFE's `clkfreq` on DD-WRT/Tomato, **not OpenWrt**):

- A Tom's Hardware thread on the R7000 describes the 40 nm BCM4709A0 as
  "usually reach[ing] about 1.2 GHz without voltage changes, and a lucky few
  reach 1.4 GHz. Only a very few will run at 1600 MHz."
- A DD-WRT forum stability-test thread on the R7000 reports **56.9 °C** (CPU)
  at the stock ~1.2 GHz, and **60 °C** at 1400 MHz; some CFE firmware
  revisions reportedly rejected overclock settings outright, and at least one
  user reported a bootloop/brick after setting 1400 MHz.
- The specific "~80-90 °C under a small overclock" figure referenced when
  this build was planned could not be re-sourced to a specific thread during
  either pass (the likely source threads are behind bot protection); treat it
  as plausible but not independently re-confirmed here.
- The DD-WRT wiki's general overclocking guidance for this hardware line
  warns it "can brick or physically destroy your router," with no
  vendor/community support for damaged units.

None of this is an OpenWrt, or R8000-specific, data point - it is included
only to make clear that even the DD-WRT/Tomato-era `clkfreq` mechanism this
SoC family is known for runs meaningfully hot, on a board design (the R7000)
that is not identical to the R8000's three-radio layout and almost certainly
has different thermal headroom, and that it relies on vendor-firmware boot
code OpenWrt does not have.

## If you want to pursue this yourself

Do not reuse the CFE `clkfreq` approach under OpenWrt without first writing
the early-boot NVRAM-reading code OpenWrt's own boot path would need (it does
not read or interpret `clkfreq` today - re-confirmed directly against
mainline Linux and the pinned `openwrt-25.12` `bcm53xx` tree, not just
asserted). A real OpenWrt-side overclock here starts with upstreaming
`cpufreq-dt`/`operating-points-v2` support to `bcm4709.dtsi`, a real
`.set_rate` implementation in `clk-iproc-armpll.c` (the register fields are
named above; nobody has published what a safe write sequence to them looks
like), and a core-parking notifier comparable to the MX4300's - genuine
kernel work, ideally done with a thermal camera, a spare router, and a way to
recover from a hung CPU clock mid-transition, not a config flag copied from a
different SoC's already-finished plumbing.

## What the R8000's own CFE does (2026-11-24)

Read from the running router (read-only) and from the `boot` partition
backup (`mtd0`) taken before this image was flashed:

- `nvram get clkfreq` -> `1000,800` (ARM MHz, DDR MHz); `sdram_ncdl=0`;
  `cfe_version=v1.0.8`; BogoMIPS 1000 (matches 1000 MHz on this kernel).
- `mtd0` holds a small loader plus an LZMA-compressed CFE (stream at offset
  `0x1c004`, 326112 bytes unpacked). The unpacked CFE contains Broadcom's
  `board_clock_init()` strings: `clkfreq`, `sdram_ncdl`, `DDR Clock: %u MHz`,
  `Warning: invalid DDR setting of %u MHz ignored. DDR frequency will be set
  to %u MHz.`, `Info: DDR frequency set from clkfreq=%u,*%u*`, `coma_swreg`.
  This is the code path (`bcm947xx_machdep.c` -> `si_arm_setclock()` in the
  SDK's `hndarm_ca9.c`) that parses `clkfreq` and programs the ARM PLL.
- Its ARM clock table (unpacked offset `0x4f524`) is the **old two-column
  form**: `{600, 0x1003001}, {800, 0x1004001}, {1000, 0x1005001},
  {1200, 0x1006001}, {1400, 0x1007001}, {1600, 0x1008001}` - MHz and PLL
  control word, with **no per-package "supported" column**. Newer SDK CFEs
  (FreshTomato/Merlin `shared/hndarm_ca9.c`) add one that limits a BCM4709
  (package 0) to 1000 MHz and turns any higher request into a ~100 MHz CPU;
  this CFE has no such gate, so it will program 1200/1400/1600 if asked.
  (Inference from the table shape; the code itself was not disassembled.)
  The DDR table before it is 333/389/400/533/666/775/800 MHz.
- OpenWrt's `nvram` tool (`package/utils/nvram`) writes the `nvram` MTD
  partition, the same one CFE reads.

So an overclock under OpenWrt is a one-line NVRAM change, and the risk is
the classic one: R7000 owners (same BCM4709A0, older CFEs like this one)
report 1200 MHz generally fine and 1400 MHz sometimes boot-looping before
the kernel starts. No report of 1200+ on an R8000 was found. There is no
voltage control: the core supply is a fixed board regulator (CFE only
toggles an optional `coma_swreg` GPIO); nothing in CFE, the DT or the kernel
can undervolt or overvolt. **Undervolting is not possible in software.**

### Prepared procedure (NOT executed - needs the owner's approval)

Risk: an unstable clock can hang CFE or the kernel on every boot. Recovery
then needs **physical access** (serial console; see below). Do not do this on
a router you cannot reach.

1. Prerequisites: serial console wired and tested (R8000 UART header,
   3.3 V TTL, 115200 8N1 - see the OpenWrt wiki R8000 page); the `mtd1`
   (`nvram`) backup at hand; confirm you can interrupt CFE (Ctrl-C at power
   on gives `CFE>`).
2. Record the baseline: `nvram get clkfreq` (`1000,800`), BogoMIPS (1000),
   an `openssl speed -elapsed aes-128-cbc` or the hairpin forwarding test
   (`tools/perftest/hairpin.sh`), and SoC temperature if available.
3. Change only the ARM clock, never DDR: `nvram set clkfreq=1200,800 &&
   nvram commit && reboot`. (Not 1400/1600 first.)
4. Verify: SSH back in, BogoMIPS should read 1200, rerun the benchmark,
   watch stability for hours (`logread`, uptime) and temperature by touch/IR.
5. Roll back from a booting system: `nvram set clkfreq=1000,800 && nvram
   commit && reboot`.
6. Roll back from a non-booting system (serial): Ctrl-C into `CFE>`, then
   `nvram set clkfreq=1000,800`, `nvram commit`, `reboot`. If CFE itself
   hangs before the prompt at 1200 (unlikely - the PLL is programmed early,
   but a hang there means no prompt), the remaining path is erasing the
   nvram partition so CFE falls back to its built-in defaults (which carry
   `clkfreq=1000,800`, visible in `mtd0` at offset `0x47c`): whether the
   R8000's reset-button-at-power-on does this is **unverified**; otherwise a
   JTAG/flash-programmer job. Afterwards restore `mtd1` from the backup to
   get Netgear's board data (MACs, Wi-Fi calibration variables) back.

Expected gain if 1200 is stable: up to +20 % on CPU-bound work (small-packet
forwarding, Wi-Fi, VPN). Full-size wired routing is already at the gigabit
wire with software offloading and would not change.
