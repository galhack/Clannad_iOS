#!/bin/bash
# Build with automatic signing and install the app onto a connected device.
#
#   tools/apple/install_device.sh ios          # iPhone / iPad
#   tools/apple/install_device.sh visionos     # Apple Vision Pro
#   tools/apple/install_device.sh ios <udid>   # explicit device
#
# The bundle id is org.local.clannad.${CLANNAD_TEAM}; the device must be paired
# and unlocked, and Xcode must have a signed-in Apple ID (Xcode › Settings ›
# Accounts).  This is the developer path; players sideload the unsigned IPA with
# Sideloadly instead (tools/apple/build_ipa.sh).
#
# Environment overrides:
#   CLANNAD_TEAM   Apple Developer team id (or app/.team)
#   DEVELOPER_DIR  Xcode to use
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${1:-ios}"
UDID="${2:-}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TMPDIR="${CLANNAD_TMPDIR:-$ROOT/build/tmp}"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/ModuleCache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

TEAM="${CLANNAD_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$ROOT/app/.team" ]; then TEAM="$(tr -d ' \n' < "$ROOT/app/.team")"; fi
[ -n "$TEAM" ] || { echo "error: set CLANNAD_TEAM or app/.team" >&2; exit 1; }
BUNDLE_ID="org.local.clannad.$TEAM"

case "$PLATFORM" in
ios)
	PRODUCTS="Release-iphoneos"
	DEVICES="$("$DEVELOPER_DIR/usr/bin/devicectl" list devices 2>/dev/null | awk '/iPhone|iPad/ && /connected|available/ {print $3}')" ;;
visionos)
	PRODUCTS="Release-xros"
	DEVICES="$("$DEVELOPER_DIR/usr/bin/devicectl" list devices 2>/dev/null | awk '/Vision/ && /connected|available/ {print $3}')" ;;
*) echo "usage: $0 [ios|visionos] [udid]" >&2; exit 2 ;;
esac
if [ -z "$UDID" ]; then
	UDID="$(echo "$DEVICES" | head -1)"
	[ -n "$UDID" ] || { echo "error: no $PLATFORM device found; pass a UDID" >&2; exit 1; }
fi
echo "==> device $UDID (bundle $BUNDLE_ID)"

"$ROOT/tools/apple/gen_project.sh" >/dev/null

LOG="$ROOT/build/install-$PLATFORM-build.log"
mkdir -p "$ROOT/build"
DD="$ROOT/build/dd-install-$PLATFORM"
if ! xcodebuild -project "$ROOT/app/Clannad.xcodeproj" -scheme Clannad -configuration Release \
	-destination "id=$UDID" -derivedDataPath "$DD" \
	-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build >"$LOG" 2>&1; then
	grep -E "error:" "$LOG" | head -10 >&2 || true
	echo "build failed; full log: $LOG" >&2
	exit 1
fi
grep -E "BUILD SUCCEEDED" "$LOG" | tail -1

APP="$DD/Build/Products/$PRODUCTS/Clannad.app"
[ -d "$APP" ] || { echo "error: missing $APP" >&2; exit 1; }
"$DEVELOPER_DIR/usr/bin/devicectl" device install app --device "$UDID" "$APP" 2>&1 | tail -5
echo "installed; launch with:"
echo "  $DEVELOPER_DIR/usr/bin/devicectl device process launch --device $UDID $BUNDLE_ID"
