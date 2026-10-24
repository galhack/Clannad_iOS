#!/bin/bash
# Sign and install the app with an EXISTING development provisioning profile.
#
#   tools/apple/sign_and_install_with_profile.sh ios <profile> [udid ...]
#   tools/apple/sign_and_install_with_profile.sh visionos <profile> [udid ...]
#
# Why this exists: `xcodebuild -allowProvisioningUpdates` needs a developer
# account signed in to Xcode.  When one is not visible to the command line (for
# example because Xcode is signed in under another macOS user, or Xcode created
# a profile once and the session is gone), the build can still be signed
# manually: the Apple Development certificate lives in the login keychain and a
# matching .mobileprovision in
#   ~/Library/Developer/Xcode/UserData/Provisioning Profiles
# is enough for codesign + devicectl.
#
# The profile must already contain the bundle id and the target device UDIDs.
# Xcode creates such a profile the first time you press Run on a device with
# the target selected ("iOS Team Provisioning Profile: <bundle id>", platform
# list includes iOS and/or visionOS), and it can be reused for later builds
# until it expires.
#
# Environment overrides:
#   CLANNAD_TEAM      team id used to derive the bundle id if the profile has none
#   CLANNAD_IDENTITY  codesign identity (default "Apple Development")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${1:?usage: $0 ios|visionos <profile> [udid ...]}"
PROFILE="${2:?missing .mobileprovision path}"
shift 2
UDIDS=("$@")
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DC="$DEVELOPER_DIR/usr/bin/devicectl"
export TMPDIR="${CLANNAD_TMPDIR:-$ROOT/build/tmp}"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/ModuleCache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

case "$PLATFORM" in
ios) PRODUCTS="Release-iphoneos"; DEST="generic/platform=iOS" ;;
visionos) PRODUCTS="Release-xros"; DEST="generic/platform=visionOS" ;;
*) echo "usage: $0 ios|visionos <profile> [udid ...]" >&2; exit 2 ;;
esac
[ -f "$PROFILE" ] || { echo "error: no profile at $PROFILE" >&2; exit 1; }

# --- decode the profile (CMS -> plist) without the security tool -------------
PLIST="$TMPDIR/profile.plist"
if ! /usr/bin/openssl cms -verify -noverify -inform DER -in "$PROFILE" -out "$PLIST" 2>/dev/null; then
	/usr/bin/openssl smime -verify -noverify -inform DER -in "$PROFILE" -out "$PLIST" 2>/dev/null
fi
[ -s "$PLIST" ] || { echo "error: cannot decode $PROFILE" >&2; exit 1; }

read -r APPID TEAM <<<"$(python3 - "$PLIST" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
e = p.get("Entitlements", {})
print(e.get("application-identifier", "-"), (p.get("TeamIdentifier") or ["-"])[0])
PY
)"
[ "$APPID" != "-" ] || { echo "error: profile has no application-identifier" >&2; exit 1; }
BUNDLE_ID="${APPID#*.}"           # TEAM.bundle.id -> bundle.id
echo "==> profile app id $APPID (bundle $BUNDLE_ID, team $TEAM)"

python3 - "$PLIST" "$TMPDIR/entitlements.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
plistlib.dump(p["Entitlements"], open(sys.argv[2], "wb"))
PY

# --- build unsigned, then sign by hand --------------------------------------
"$ROOT/tools/apple/gen_project.sh" >/dev/null
DD="$ROOT/build/dd-profile-$PLATFORM"
LOG="$ROOT/build/profile-$PLATFORM-build.log"
echo "==> building $PLATFORM unsigned"
xcodebuild -project "$ROOT/app/Clannad.xcodeproj" -scheme Clannad -configuration Release \
	-destination "$DEST" -derivedDataPath "$DD" ARCHS=arm64 \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
	PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$LOG" 2>&1 || {
	grep -E "error:" "$LOG" | head -8 >&2
	echo "build failed; log: $LOG" >&2
	exit 1
}
APP="$DD/Build/Products/$PRODUCTS/Clannad.app"
[ -d "$APP" ] || { echo "error: no $APP" >&2; exit 1; }

echo "==> codesigning with ${CLANNAD_IDENTITY:-Apple Development}"
cp -f "$PROFILE" "$APP/embedded.mobileprovision"
codesign -f -s "${CLANNAD_IDENTITY:-Apple Development}" \
	--entitlements "$TMPDIR/entitlements.plist" --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier" || true

# --- install -----------------------------------------------------------------
if [ ${#UDIDS[@]} -eq 0 ]; then
	case "$PLATFORM" in
	ios) PATTERN='iPhone|iPad' ;;
	visionos) PATTERN='Vision' ;;
	esac
	while IFS= read -r line; do
		[ -n "$line" ] && UDIDS+=("$line")
	done < <("$DC" list devices 2>/dev/null |
		awk -v p="$PATTERN" '$0 ~ p && /connected|available/ && !/simulated/ {print $3}')
fi
[ ${#UDIDS[@]} -gt 0 ] || { echo "error: no $PLATFORM device found; pass a UDID" >&2; exit 1; }
for udid in "${UDIDS[@]}"; do
	echo "==> installing on $udid"
	"$DC" device install app --device "$udid" "$APP" 2>&1 | tail -3
done
echo "done. Bundle id on device: $BUNDLE_ID"
