#!/bin/bash
# Static checks of one profile's build output (out/<profile>/), run by
# scripts/build.sh after every build. Exits non-zero, printing every failure
# first, if anything looks wrong - this is meant to catch a broken or
# incomplete image before it is ever published, not to prove the firmware
# works on real hardware (it cannot: see the README's "What's verified"
# section for the difference).
set -u
dir=${1:?usage: $0 out/PROFILE}
fail=0
note() { echo "FAIL: $1" >&2; fail=1; }

images=()
for f in "$dir"/*netgear_r8000*; do
	case "$f" in
	*.manifest) continue ;; # a package list, not a flashable image - naturally a few KB
	esac
	images+=("$f")
done
if [ "${#images[@]}" = 0 ]; then
	note "no netgear_r8000 image files in $dir"
else
	for f in "${images[@]}"; do
		size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
		# The bcm53xx image for this device has historically been a few MB;
		# anything far outside that is almost certainly a broken build, not a
		# real firmware image.
		[ "$size" -ge 2000000 ] || note "$f is suspiciously small ($size bytes)"
		[ "$size" -le 64000000 ] || note "$f is suspiciously large ($size bytes) - is this a 128 MB flash device?"
	done
fi

[ -s "$dir/sha256sums" ] || note "no sha256sums in $dir"
if [ -s "$dir/sha256sums" ] && [ -e "${images[0]}" ]; then
	(cd "$dir" && sha256sum -c sha256sums >/dev/null 2>&1) || note "sha256sums does not match the images in $dir"
fi

config=$dir/config.full
if [ -s "$config" ]; then
	grep -qx 'CONFIG_TARGET_bcm53xx_generic_DEVICE_netgear_r8000=y' "$config" ||
		note "config.full was not built for netgear_r8000"
	grep -qx 'CONFIG_PACKAGE_wpad-openssl=y' "$config" ||
		note "config.full does not have full wpad (wpad-openssl) - unifi-openwrt needs it, see docs/unifi-adoption.md"
	grep -q '^CONFIG_PACKAGE_wpad-basic-mbedtls=y$' "$config" &&
		note "config.full still has wpad-basic-mbedtls selected alongside wpad-openssl"
	grep -q '^CONFIG_PACKAGE_kmod-bgmac-fa' "$config" &&
		note "config.full selects a Flow Accelerator (FA) package - this repository does not include one (see docs/ctf-fa.md); check configs/ and profiles/ for an accidental selection"
else
	note "no config.full in $dir"
fi

info=$dir/build-info
if [ -s "$info" ]; then
	grep -q '^PROFILE=' "$info" || note "build-info has no PROFILE="
	grep -q '^UPSTREAM_COMMIT=' "$info" || note "build-info has no UPSTREAM_COMMIT="
else
	note "no build-info in $dir"
fi

if [ $fail = 0 ]; then
	echo "validate-images: $dir looks sane (static checks only - see README, this is not a hardware test)"
fi
exit $fail
