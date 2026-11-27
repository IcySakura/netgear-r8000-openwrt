#!/bin/bash
# Reproducible build of OpenWrt for the Netgear R8000.
#
#   scripts/build.sh [-j N] [--clean] [--profile NAME]... [--overlay DIR]...
#
# Fetches the pinned upstream tree (upstream/openwrt.conf) into $SRC, applies
# patches/*.patch, pins the feeds (upstream/feeds.conf), then builds one image
# per profile (profiles/NAME.packages, default: "default") in the same tree, so
# every profile after the first is an incremental build. Each profile gets
# overlays/common plus any --overlay directories as the image's "files/".
#
# Results: $OUT/<profile>/ (images, manifest, config, sha256sums), validated
# with tools/validate-images.sh.
#
# Environment: SRC (default build/openwrt), DL_DIR (default build/dl),
# OUT (default out).
set -euo pipefail

# Parse the whole script before running it, so editing it mid-build is safe.
{

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-$TOP/build/openwrt}
DL_DIR=${DL_DIR:-$TOP/build/dl}
OUT=${OUT:-$TOP/out}
JOBS=$(nproc)
CLEAN=
PROFILES=()
OVERLAYS=()

while [ $# -gt 0 ]; do
	case "$1" in
	-j) JOBS=$2; shift ;;
	-j*) JOBS=${1#-j} ;;
	--clean) CLEAN=1 ;;
	--profile) PROFILES+=("$2"); shift ;;
	--overlay) OVERLAYS+=("$(cd "$2" && pwd)"); shift ;;
	*) echo "usage: $0 [-j N] [--clean] [--profile NAME]... [--overlay DIR]..." >&2; exit 2 ;;
	esac
	shift
done
[ ${#PROFILES[@]} -gt 0 ] || PROFILES=(default)
for p in "${PROFILES[@]}"; do
	[ -f "$TOP/profiles/$p.packages" ] || { echo "no such profile: profiles/$p.packages" >&2; exit 2; }
done

# OpenWrt's host tools trip over unusual PATH entries (e.g. the Windows
# directories WSL appends, which contain spaces): drop those, keep the rest.
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -e '^/mnt/' -e ' ' | paste -sd: -)
export PATH=${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}

. "$TOP/upstream/openwrt.conf"
REPO_COMMIT=$(git -C "$TOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

# --- Source tree --------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$SRC"
	git -C "$SRC" init -q
	git -C "$SRC" remote add origin "$OPENWRT_URL"
fi

cd "$SRC"
stamp() { (echo "$OPENWRT_URL $OPENWRT_COMMIT"; cat "$TOP"/patches/*.patch "$TOP/upstream/feeds.conf") | sha256sum | cut -d' ' -f1; }
am() { git -c user.name=r8000-openwrt-build -c user.email=r8000-openwrt-build@localhost am -q --keep-cr "$@"; }

# The patches do not apply to a newer upstream as they are (its lines next to
# ours moved or changed). Merge them three-way from the commit they were made
# for - the upstream pin of this repository's HEAD - and write the merged
# patches back to patches/. A real conflict (upstream changed the very lines a
# patch changes) still fails.
merge_patches() {
	local base p tmp i=0

	base=$(git -C "$TOP" show HEAD:upstream/openwrt.conf 2>/dev/null | sed -n 's/^OPENWRT_COMMIT=//p')
	if [ -z "$base" ] || [ "$base" = "$OPENWRT_COMMIT" ]; then
		echo "The patches in patches/ do not apply to $OPENWRT_COMMIT." >&2
		exit 1
	fi
	echo ">>> The patches do not apply as they are; merging them three-way from ${base::12}"
	git fetch -q --depth 1 origin "$base"
	git checkout -q -f --detach "$base"
	am "$TOP"/patches/*.patch
	git checkout -q -f --detach "$OPENWRT_COMMIT"
	if ! am -3 "$TOP"/patches/*.patch; then
		echo "Conflict: the patch above does not merge with upstream ${OPENWRT_COMMIT::12}:" >&2
		git diff --name-only --diff-filter=U >&2
		git am --abort
		exit 1
	fi
	tmp=$(mktemp -d)
	git format-patch -q --no-signature --zero-commit -o "$tmp" "$OPENWRT_COMMIT..HEAD"
	for p in "$TOP"/patches/*.patch; do
		i=$((i + 1))
		cp "$(ls "$tmp"/*.patch | sed -n "${i}p")" "$p"
	done
	rm -rf "$tmp"
	echo ">>> Merged; patches/ now holds the patches as they apply to ${OPENWRT_COMMIT::12}"
}

STAMP=$(stamp)
if [ "$(cat .r8000-openwrt-stamp 2>/dev/null)" != "$STAMP" ] || [ -n "$CLEAN" ]; then
	echo ">>> Checking out $OPENWRT_COMMIT and applying patches"
	git fetch -q --depth 1 origin "$OPENWRT_COMMIT"
	git checkout -q -f --detach "$OPENWRT_COMMIT"
	git clean -q -fd -- target package drivers arch
	if ! am "$TOP"/patches/*.patch; then
		git am --abort
		merge_patches
		STAMP=$(stamp)
	fi
	# The package metadata cache does not track every file a patch can
	# touch: drop it so defconfig sees them.
	rm -rf tmp/info
	echo "$STAMP" > .r8000-openwrt-stamp
fi

mkdir -p "$DL_DIR"
[ -e dl ] || ln -s "$DL_DIR" dl
cp "$TOP/upstream/feeds.conf" feeds.conf

./scripts/feeds update -a
./scripts/feeds install -a

# --- One image per profile ------------------------------------------------------
BIN=bin/targets/bcm53xx/generic
for PROFILE in "${PROFILES[@]}"; do
	echo ">>> Profile $PROFILE"

	rm -rf files
	mkdir -p files/etc/r8000
	cp -a "$TOP/overlays/common/." files/
	for o in "${OVERLAYS[@]}"; do cp -a "$o/." files/; done
	cp "$TOP/profiles/$PROFILE.packages" files/etc/r8000/profile.packages
	cat > files/etc/r8000/build-info <<-EOF
		PROFILE=$PROFILE
		REPO_COMMIT=$REPO_COMMIT
		UPSTREAM_BRANCH=$OPENWRT_BRANCH
		UPSTREAM_COMMIT=$OPENWRT_COMMIT
		BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	EOF

	cp "$TOP/configs/r8000.config" .config
	"$TOP/scripts/profile.sh" apply .config "$TOP/configs/base.packages" "$TOP/profiles/$PROFILE.packages"
	make defconfig >/dev/null
	# defconfig drops a symbol it cannot select without a word; here that is an error
	dropped=$(grep -E '^CONFIG_[A-Za-z0-9_-]+=' "$TOP/configs/r8000.config" | while read -r l; do
		grep -qxF "$l" .config || echo "$l"; done)
	[ -z "$dropped" ] || { echo "defconfig dropped from configs/r8000.config:" >&2; echo "$dropped" >&2; exit 1; }
	"$TOP/scripts/profile.sh" check .config "$TOP/configs/base.packages" "$TOP/profiles/$PROFILE.packages"

	rm -f "$BIN"/*netgear_r8000*
	make -j"$JOBS" download
	if [ -f "$TOP/tools/bcm43602-sae-patch/patch_fw.py" ]; then
		make -j"$JOBS" tools/install toolchain/install package/firmware/linux-firmware/compile
		TC_BIN=$(echo staging_dir/toolchain-*/bin)
		STOCK_FW=$(echo staging_dir/target-*/root-bcm53xx/lib/firmware/brcm/brcmfmac43602-pcie.bin)
		if [ -f "$STOCK_FW" ]; then
			PATCH_TMP=$(mktemp -d)
			STAGING_DIR="$SRC/staging_dir" "$TC_BIN"/*-gcc -mcpu=cortex-r4 -mthumb -Os \
				-ffreestanding -nostdlib -fno-builtin -fno-pie -fno-stack-protector \
				-T "$TOP/tools/bcm43602-sae-patch/sae_patch.ld" \
				"$TOP/tools/bcm43602-sae-patch/sae_patch.c" -o "$PATCH_TMP/sae_patch.elf"
			"$TC_BIN"/*-objcopy -O binary "$PATCH_TMP/sae_patch.elf" "$PATCH_TMP/sae_patch.bin"
			mkdir -p files/lib/firmware/brcm
			python3 "$TOP/tools/bcm43602-sae-patch/patch_fw.py" \
				"$STOCK_FW" "$PATCH_TMP/sae_patch.elf" "$PATCH_TMP/sae_patch.bin" \
				"$(echo "$TC_BIN"/*-nm)" files/lib/firmware/brcm/brcmfmac43602-pcie.bin
			rm -rf "$PATCH_TMP"
		fi
	fi
	make -j"$JOBS" || make -j1 V=s

	dest=$OUT/$PROFILE
	rm -rf "$dest"
	mkdir -p "$dest"
	cp "$BIN"/*netgear_r8000* "$BIN"/profiles.json "$dest"/ 2>/dev/null || cp "$BIN"/*netgear_r8000* "$dest"/
	cp .config "$dest/config.full"
	cp files/etc/r8000/build-info "$dest/build-info"
	(cd "$dest" && sha256sum -- *netgear_r8000* > sha256sums)

	"$TOP/tools/validate-images.sh" "$dest"
	echo ">>> Images in $dest"
done
exit 0
}
