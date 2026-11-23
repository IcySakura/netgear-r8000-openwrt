# CPU overclocking: investigated, not implemented

Short version: **this build does not include an overclock option.** Unlike
the other two repositories this one follows the conventions of (both of
which ship a real, reversible overclock feature for their own SoCs - see
their `docs/cpu-overclock.md`), there is currently nothing for a comparable
feature on the R8000 to attach to.

## What was checked

The R8000's BCM4709A0 is a dual-core ARM Cortex-A9 at a fixed ~1000 MHz. The
full device-tree chain was read directly (`bcm4709-netgear-r8000.dts` ->
`bcm4709.dtsi` -> `bcm4708.dtsi` -> `bcm5301x.dtsi`):

- **No `operating-points-v2` property exists anywhere in that chain.** The
  `cpus` node declares two `arm,cortex-a9` cores with
  `enable-method = "brcm,bcm-nsp-smp"` and nothing describing alternate
  frequencies.
- The actual clock tree is a 25 MHz fixed oscillator feeding an `a9pll` node
  (`compatible = "brcm,nsp-armpll"`, driven by the mainline `drivers/clk/bcm/clk-nsp.c`
  kernel driver), plus separate `lcpll0`/`genpll` PLLs for peripherals. There
  is no `cpufreq-dt` binding anywhere, and a full grep of OpenWrt's
  `target/linux/bcm53xx/` tree (patches, kernel configs, base-files) for
  "cpufreq" returns **zero matches**.
- **Verdict: there is no OS-level dynamic frequency scaling on this platform
  in current OpenWrt at all** - not "present but disabled," not "present but
  undocumented." The CPU simply runs at whatever rate the `a9pll` hardware
  registers already held when Linux took over, set by the bootloader (CFE)
  or left at reset defaults.

Compare this with the Linksys MX4300 (Qualcomm IPQ8174) overclock this
convention is based on, which works by feeding the CPU cores from an
alternate, already-present PLL (GPLL2) the SoC's clock driver already exposes
- a real, if nonstandard, OS-level mechanism to build a LuCI app and preset
table around. The R8000 has nothing equivalent exposed to the OS today.

## What it would take

Either of:

1. A kernel patch that calls `clk_set_rate()` on the `a9pll` clock directly.
   The underlying `iproc_armpll_setup()` PLL driver can, in principle, set
   arbitrary dividers - it is just never wired up to anything a user can
   change at runtime in OpenWrt today. This would be new driver/DTS work, not
   a config toggle.
2. Going back to the CFE bootloader's own NVRAM `clkfreq` variable (the
   `nvram set clkfreq=1400,800; nvram commit; reboot` mechanism DD-WRT/Tomato
   used on this SoC family). This only works under those firmwares' own boot
   flow; it is not how OpenWrt's boot path uses CFE, and nothing in the
   current OpenWrt bcm53xx target reads or writes `clkfreq`.

Either path is real kernel/bootloader engineering on hardware this repository
cannot test on - not something to ship as a "config option" per the original
brief, because there is no existing on/off switch to wrap. Building (1) from
scratch and shipping it as a default-off, "experimental" option without ever
having run it on a physical R8000 would be exactly the kind of untested,
self-written low-level change this repository is trying to avoid (see
`docs/ctf-fa.md` for the same reasoning applied to FA offload).

## What was found about overclocking this SoC family

No R8000-specific overclock thread was found (the OpenWrt forum archive
thread referenced in community discussion, and the DD-WRT wiki's
overclocking page, both returned bot-protection "Access Denied" pages to
every fetch attempt and could not be read). What follows is for the closely
related **R7000** (same BCM4709A0 SoC, via CFE's `clkfreq` on DD-WRT/Tomato,
**not OpenWrt**):

- A Tom's Hardware thread on the R7000 describes the 40 nm BCM4709A0 as
  "usually reach[ing] about 1.2 GHz without voltage changes, and a lucky few
  reach 1.4 GHz. Only a very few will run at 1600 MHz."
- A DD-WRT forum stability-test thread on the R7000 reports **56.9 °C** (CPU)
  at the stock ~1.2 GHz, and **60 °C** at 1400 MHz; some CFE firmware
  revisions reportedly rejected overclock settings outright, and at least one
  user reported a bootloop/brick after setting 1400 MHz.
- The specific "~80-90 °C under a small overclock" figure referenced when
  this build was planned could not be re-sourced to a specific thread during
  this investigation (the likely source threads are behind bot protection);
  treat it as plausible but not independently re-confirmed here.
- The DD-WRT wiki's general overclocking guidance for this hardware line
  warns it "can brick or physically destroy your router," with no
  vendor/community support for damaged units.

None of this is an OpenWrt, or R8000-specific, data point - it is included
only to make clear that even the DD-WRT/Tomato-era `clkfreq` mechanism this
SoC family is known for runs meaningfully hot, on a board design (the R7000)
that is not identical to the R8000's three-radio layout and almost certainly
has different thermal headroom.

## If you want to pursue this yourself

Do not reuse the CFE `clkfreq` approach under OpenWrt without first checking
whether OpenWrt's CFE boot path on this device even reads that NVRAM variable
(as far as this investigation found, it does not). A real OpenWrt-side
overclock here starts with upstreaming `cpufreq-dt`/`operating-points-v2`
support to `bcm4709.dtsi` and `clk-nsp.c` - that is genuine kernel work,
ideally done with a thermal camera and a spare router, not a config flag
copied from a different SoC.
