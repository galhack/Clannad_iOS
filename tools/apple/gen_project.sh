#!/bin/sh
# Generate app/Clannad.xcodeproj from app/project.yml with XcodeGen.
#
#   CLANNAD_TEAM=<your team id> tools/apple/gen_project.sh
#
# Without CLANNAD_TEAM the team id is read from app/.team (one line, not in
# git) when that file exists; the Mac build needs none (it is signed ad-hoc).
# XcodeGen comes from build/tools (cached or downloaded on first use) or PATH,
# so nothing has to be installed system-wide.
#
# Environment overrides:
#   CLANNAD_TEAM      Apple Developer team id for device builds
#   XCODEGEN_VERSION  XcodeGen release to download (default 2.46.0)
#
# The spec itself carries the Swift flags this sandbox needs
# (OTHER_SWIFT_FLAGS: -disable-sandbox); nothing is injected from here.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPEC="$ROOT/app/project.yml"

if [ ! -f "$SPEC" ]; then
	echo "error: $SPEC is missing: generate needs the XcodeGen spec of the app shell" >&2
	exit 1
fi

XG="$(command -v xcodegen || true)"
if [ -z "$XG" ]; then
	XG="$ROOT/build/tools/xcodegen/bin/xcodegen"
	if [ ! -x "$XG" ]; then
		VERSION="${XCODEGEN_VERSION:-2.46.0}"
		mkdir -p "$ROOT/build/tools"
		echo "downloading XcodeGen $VERSION into build/tools..." >&2
		if ! curl -fsSL -o "$ROOT/build/tools/xcodegen.zip" \
			"https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"; then
			echo "error: could not download XcodeGen $VERSION (no network?); install it yourself and rerun" >&2
			exit 1
		fi
		unzip -q -o "$ROOT/build/tools/xcodegen.zip" -d "$ROOT/build/tools"
	fi
fi
if [ ! -x "$XG" ]; then
	echo "error: XcodeGen is not available at $XG" >&2
	exit 1
fi

if [ -z "${CLANNAD_TEAM:-}" ] && [ -f "$ROOT/app/.team" ]; then
	CLANNAD_TEAM="$(tr -d ' \n' < "$ROOT/app/.team")"
fi
export CLANNAD_TEAM="${CLANNAD_TEAM:-}"
export CLANNAD_BUNDLE_ID="${CLANNAD_BUNDLE_ID:-org.local.clannad${CLANNAD_TEAM:+.$CLANNAD_TEAM}}"

if [ -z "$CLANNAD_TEAM" ]; then
	echo "note: CLANNAD_TEAM is empty and app/.team does not exist;" >&2
	echo "      the Mac build still works (ad-hoc), device builds need a team id." >&2
fi

"$XG" generate --spec "$SPEC" --project "$ROOT/app"
