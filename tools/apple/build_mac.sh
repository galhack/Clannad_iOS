#!/bin/sh
# Build the Mac application (Mac Catalyst), sign it ad-hoc so it runs
# locally, and zip it.
#
#   tools/apple/build_mac.sh
#
# The result is build/Clannad-mac.zip with Clannad.app inside (and the .app
# itself in build/Clannad-mac.app); no game data goes into it.  The app is
# signed ad-hoc ("-"), not with a Developer ID: on another Mac open it the
# first time with right-click > Open (or allow it in System Settings >
# Privacy & Security), since it is not notarised.
#
# The game folder is not copied: the app asks for it with a folder picker and
# remembers the choice; saves stay in <gameRoot>/savedata.
#
# Environment overrides:
#   DEVELOPER_DIR   Xcode to use (default /Applications/Xcode.app/Contents/Developer)
#   CLANNAD_TEAM    Apple Developer team id, for an XcodeGen project run
#   CLANNAD_MAC_ARCHS  defaults to arm64; x86_64 also needs its engine slice
#   CLANNAD_TMPDIR  scratch directory (default build/tmp; restricted sandboxes
#                   block the default /var/folders TMPDIR)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/build/ModuleCache}"
# Keep compiler/actool scratch files inside the repository: a restricted build
# sandbox may block writes to the default TMPDIR under /var/folders.
export TMPDIR="${CLANNAD_TMPDIR:-$ROOT/build/tmp}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

"$ROOT/tools/apple/gen_project.sh"

LOG="$ROOT/build/mac-build.log"
mkdir -p "$ROOT/build"
echo "building Mac Catalyst (Release, ad-hoc signed) -> $LOG"
if ! xcodebuild -project "$ROOT/app/Clannad.xcodeproj" -scheme Clannad -configuration Release \
	-destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath "$ROOT/build/dd-mac" \
	ARCHS="${CLANNAD_MAC_ARCHS:-arm64}" \
	CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build > "$LOG" 2>&1; then
	grep -E "error:" "$LOG" | head -20 >&2 || true
	echo "build failed; full log: $LOG" >&2
	exit 1
fi
grep -E "BUILD" "$LOG" | tail -1

BUILT="$ROOT/build/dd-mac/Build/Products/Release-maccatalyst/Clannad.app"
if [ ! -d "$BUILT" ]; then
	echo "error: built app not found at $BUILT" >&2
	exit 1
fi

APP="$ROOT/build/Clannad-mac.app"
ZIP="$ROOT/build/Clannad-mac.zip"
rm -rf "$APP" "$ZIP"
ditto "$BUILT" "$APP"

# Ad-hoc sign the copy, in case the Xcode build left it unsigned.
codesign --force --sign - --timestamp=none "$APP" > /dev/null 2>&1 || true
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
	echo "app is ad-hoc signed (not notarised; first open uses right-click > Open)"
else
	echo "note: could not confirm an ad-hoc signature; the app may still run locally" >&2
fi

ditto -c -k --keepParent "$APP" "$ZIP"
SIZE="$(du -h "$ZIP" | cut -f1)"
echo "wrote ${ZIP#$ROOT/} ($SIZE; app: ${APP#$ROOT/})"
