# CPU Overclocking

**CPU overclocking is not included in this build.**

## Why there is no runtime overclock

- **No `cpufreq` driver:** Mainline Linux has no `cpufreq` driver for BCM4709A0 / Northstar (`arch/arm/mach-bcm/bcm_5301x.c` registers no power-management or frequency-scaling hooks, and OpenWrt `bcm53xx` builds with `CONFIG_CPU_FREQ` unset).
- **Read-only ARM PLL driver:** `drivers/clk/bcm/clk-iproc-armpll.c` implements only `.recalc_rate` (read-only); it has no `.set_rate` implementation or safe CPU clock-parking transition path.
- **No voltage control:** Core voltage on BCM4709A0 boards is fixed in hardware with no OS-accessible regulator scaling.

## Bootloader `clkfreq` note

On this unit's CFE bootloader, NVRAM `clkfreq` (default `1000,800`) is parsed by CFE itself during boot before Linux starts. This repository deliberately does not modify `clkfreq` because:
- An unstable clock setting can prevent boot and requires serial-console recovery.
- Running above stock frequency without voltage control increases heat inside the three-radio R8000 enclosure.
- With software or hardware flow offloading enabled, stock 1 GHz already saturates Gigabit Ethernet.
