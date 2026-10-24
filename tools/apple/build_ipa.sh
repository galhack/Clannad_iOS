#!/bin/sh
# Build an unsigned .ipa for Sideloadly / AltStore, which sign it with your
# own Apple ID when they install it.
#
#   tools/apple/build_ipa.sh [ios|visionos]     (default ios)
#
# The result is build/Clannad-<platform>.ipa (a few MB: the app, the engine
# and the icons; never any game data).  Signing is left to the sideloading
# tool, so no team id is needed here.
#
# Environment overrides:
#   DEVELOPER_DIR   Xcode to use (default /Applications/Xcode.app/Contents/Developer)
#   CLANNAD_TEAM    Apple Developer team id, for an XcodeGen project run
#   CLANNAD_TMPDIR  scratch directory (default build/tmp; restricted sandboxes
#                   block the default /var/folders TMPDIR)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${1:-ios}"
case "$PLATFORM" in
	ios) DEST="generic/platform=iOS"; PRODUCTS="Release-iphoneos" ;;
	visionos) DEST="generic/platform=visionOS"; PRODUCTS="Release-xros" ;;
	*) echo "usage: $0 [ios|visionos]" >&2; exit 2 ;;
esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/build/ModuleCache}"
# Keep compiler/actool scratch files inside the repository: a restricted build
# sandbox may block writes to the default TMPDIR under /var/folders.
export TMPDIR="${CLANNAD_TMPDIR:-$ROOT/build/tmp}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

if ! xcrun --sdk "$([ "$PLATFORM" = visionos ] && echo xros || echo iphoneos)" --show-sdk-path > /dev/null 2>&1; then
	echo "error: this Xcode has no $PLATFORM SDK ($DEVELOPER_DIR)" >&2
	exit 1
fi

"$ROOT/tools/apple/gen_project.sh"

LOG="$ROOT/build/ipa-$PLATFORM-build.log"
mkdir -p "$ROOT/build"
echo "building $PLATFORM (Release, unsigned) -> $LOG"
if ! xcodebuild -project "$ROOT/app/Clannad.xcodeproj" -scheme Clannad -configuration Release \
	-destination "$DEST" -derivedDataPath "$ROOT/build/dd-ipa" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$LOG" 2>&1; then
	grep -E "error:" "$LOG" | head -20 >&2 || true
	echo "build failed; full log: $LOG" >&2
	exit 1
fi
grep -E "BUILD" "$LOG" | tail -1

APP="$ROOT/build/dd-ipa/Build/Products/$PRODUCTS/Clannad.app"
if [ ! -d "$APP" ]; then
	echo "error: built app not found at $APP" >&2
	grep -E "error:" "$LOG" | head -20 >&2 || true
	exit 1
fi
if [ ! -f "$APP/Clannad" ]; then
	echo "error: $APP has no Clannad executable" >&2
	exit 1
fi

STAGE="$ROOT/build/ipa-$PLATFORM"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
OUT="$ROOT/build/Clannad-$PLATFORM.ipa"
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" Payload)
SIZE="$(du -h "$OUT" | cut -f1)"
echo "wrote ${OUT#$ROOT/} ($SIZE)"
if [ "$PLATFORM" = visionos ]; then
	echo "note: this unsigned visionOS IPA must be signed by Xcode or a sideloading tool before"
	echo "      it can be installed on Apple Vision Pro; see README (Vision Pro section)."
fi
