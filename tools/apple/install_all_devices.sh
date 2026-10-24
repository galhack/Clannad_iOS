#!/bin/bash
# Build, sign and install the three device builds with the developer account
# that is signed in to Xcode, then push the game data if it is not there yet.
#
#   tools/apple/install_all_devices.sh [--no-data]
#
# Run this from the macOS user session whose Xcode has the Apple ID account
# (Xcode › Settings › Accounts).  It builds with -allowProvisioningUpdates, so
# Xcode creates the development profiles for org.local.clannad.<Team>.
#
# Environment overrides:
#   CLANNAD_TEAM   team id (or app/.team)
#   GAME_DIR       game data folder (default ./data)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DC="$DEVELOPER_DIR/usr/bin/devicectl"

TEAM="${CLANNAD_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$ROOT/app/.team" ]; then TEAM="$(tr -d ' \n' < "$ROOT/app/.team")"; fi
[ -n "$TEAM" ] || { echo "error: set CLANNAD_TEAM or app/.team" >&2; exit 1; }
BUNDLE_ID="org.local.clannad.$TEAM"
GAME_DIR="${GAME_DIR:-$ROOT/data}"
PUSH_DATA=1
[ "${1:-}" = "--no-data" ] && PUSH_DATA=0

echo "==> team $TEAM, bundle $BUNDLE_ID"

"$ROOT/tools/apple/gen_project.sh" >/dev/null

build_and_install() { # $1 = ios|visionos, $2 = products dir
	local platform="$1" products="$2"
	local dest="generic/platform=iOS"
	[ "$platform" = visionos ] && dest="generic/platform=visionOS"
	local dd="$ROOT/build/dd-install-$platform"
	local log="$ROOT/build/install-$platform.log"

	echo "==> building $platform (signed, automatic provisioning)"
	if ! xcodebuild -project "$ROOT/app/Clannad.xcodeproj" -scheme Clannad -configuration Release \
		-destination "$dest" -derivedDataPath "$dd" -allowProvisioningUpdates \
		DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$log" 2>&1; then
		grep -E "error:" "$log" | head -8 >&2
		echo "build failed; log: $log" >&2
		return 1
	fi
	local app="$dd/Build/Products/$products/Clannad.app"
	[ -d "$app" ] || { echo "error: no $app" >&2; return 1; }
	echo "signed: $(codesign -dv "$app" 2>&1 | grep -E 'Identifier|TeamIdentifier' | tr '\n' ' ')"

	local udids
	udids="$( ("$DC" list devices 2>/dev/null) | awk -v p="$platform" '
		p=="ios" && /iPhone|iPad/ && /connected|available/ {print $3}
		p=="visionos" && /Vision/ && /connected|available/ && !/simulated/ {print $3}')"
	[ -n "$udids" ] || { echo "warning: no $platform device connected" >&2; return 0; }
	for udid in $udids; do
		echo "==> installing on $udid"
		"$DC" device install app --device "$udid" "$app" 2>&1 | tail -3
		if [ "$PUSH_DATA" = 1 ] && [ -d "$GAME_DIR" ]; then
			echo "==> copying game data (skips files already up to date)"
			"$DC" device copy to --device "$udid" \
				--domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
				--source "$GAME_DIR" --destination Documents/Clannad 2>&1 | tail -2
		fi
	done
}

rc=0
build_and_install ios Release-iphoneos || rc=1
build_and_install visionos Release-xros || rc=1
echo
if [ $rc -eq 0 ]; then echo "done."; else echo "some steps failed; see build/install-*.log" >&2; fi
exit $rc
