#!/bin/bash
# Move the pins in upstream/ to the current tip of OPENWRT_BRANCH.
#
#   scripts/bump-upstream.sh
#
# Unlike the pinning scripts of other OpenWrt build repos that follow a
# third-party fork's own tested releases, this repository pins plain,
# official OpenWrt (there is no third-party "offload" fork for bcm53xx - see
# README). There is nothing to coordinate a release with: this just moves
# OPENWRT_COMMIT, and every feed in upstream/feeds.conf, to the current tip of
# the same branch (openwrt-25.12) on their own repositories.
#
# Prints what changed; exits 0 with no change when already on that commit.
# In GitHub Actions it also sets the outputs "changed" and "release" (the
# short commit, for parity with the other build repos' workflow steps).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
CONF=$TOP/upstream/openwrt.conf
FEEDS=$TOP/upstream/feeds.conf
. "$CONF"

old_commit=$OPENWRT_COMMIT
new_commit=$(git ls-remote "$OPENWRT_URL" "refs/heads/$OPENWRT_BRANCH" | awk '{print $1}')
[ -n "$new_commit" ] || { echo "could not resolve $OPENWRT_BRANCH on $OPENWRT_URL" >&2; exit 1; }
sed -i "s/^OPENWRT_COMMIT=.*/OPENWRT_COMMIT=$new_commit/" "$CONF"

old_feeds=$(cat "$FEEDS")
new_feeds=$(awk -v branch="$OPENWRT_BRANCH" '
	/^src-git / {
		name = $2
		url = $3
		sub(/\^.*/, "", url)
		cmd = "git ls-remote " url " refs/heads/" branch " | awk \x27{print $1}\x27"
		cmd | getline commit
		close(cmd)
		if (commit != "") { print name " " url "^" commit; next }
	}
	{ print }
' "$FEEDS")
printf '%s\n' "$new_feeds" > "$FEEDS"

changed=false
if [ "$old_commit" != "$new_commit" ] || [ "$old_feeds" != "$new_feeds" ]; then
	changed=true
	echo "Upstream: $OPENWRT_BRANCH ($new_commit)"
	[ "$old_commit" = "$new_commit" ] ||
		echo "Tree: https://github.com/openwrt/openwrt/compare/${old_commit:0:12}...${new_commit:0:12}"
	diff <(echo "$old_feeds" | grep '^src-git') <(echo "$new_feeds" | grep '^src-git') | sed -n 's/^> /Feed: /p' || true
else
	echo "Already on $new_commit"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "changed=$changed" >> "$GITHUB_OUTPUT"
	echo "release=${new_commit:0:12}" >> "$GITHUB_OUTPUT"
fi
