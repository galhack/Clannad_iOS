#!/bin/bash
# Copy a game directory straight into an installed app's container over USB or
# the local network (developer convenience; players use Finder sharing or the
# in-app Wi-Fi transfer instead).
#
#   tools/apple/push_data.sh <udid> [game-dir]
#
# Default game dir: ./data (i.e. the user's CLANNAD/data).  The app scans
# Documents/Clannad, so the destination is Documents/Clannad.  devicectl skips
# files that are already up to date, so an interrupted copy can just be rerun.
#
# Environment overrides:
#   CLANNAD_TEAM   Apple Developer team id (or app/.team)
#   DEVELOPER_DIR  Xcode to use
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="${1:?usage: $0 <udid> [game-dir]}"
GAME_DIR="${2:-$ROOT/data}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TEAM="${CLANNAD_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$ROOT/app/.team" ]; then TEAM="$(tr -d ' \n' < "$ROOT/app/.team")"; fi
[ -n "$TEAM" ] || { echo "error: set CLANNAD_TEAM or app/.team" >&2; exit 1; }
BUNDLE_ID="org.local.clannad.$TEAM"

[ -d "$GAME_DIR" ] || { echo "error: no game directory $GAME_DIR" >&2; exit 1; }
[ -f "$GAME_DIR/SceneZH.pck" ] || [ -f "$GAME_DIR/Scene.pck" ] || {
	echo "error: $GAME_DIR does not look like the CLANNAD data folder (no SceneZH.pck)" >&2
	exit 1
}

echo "==> $GAME_DIR -> $BUNDLE_ID:Documents/Clannad on $UDID"
du -sh "$GAME_DIR"
"$DEVELOPER_DIR/usr/bin/devicectl" device copy to \
	--device "$UDID" \
	--domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
	--source "$GAME_DIR" \
	--destination Documents/Clannad
echo "done. Launch the app, tap 重新检查, then 开始游戏."
