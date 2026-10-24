#!/bin/bash
# ---------------------------------------------------------------------------
# CLANNAD Apple port — host engine smoke test.
#
# Boots the vendored siglus_rs host engine far enough to render the title
# screen, using the built-in bounded capture path:
#
#   siglus_engine --project-dir <dir> --capture-png <png> \
#                 --capture-after-frames <N> --exit-after-capture
#
# This is the fastest end-to-end check that the engine still:
#   * resolves the localized scene archive (SceneZH.pck),
#   * recovers/loads the 16-byte secondary key (never printed),
#   * parses SceneZH.pck and runs the boot/menu scenes,
#   * renders a frame (PNG is written).
#
# Usage:
#   tools/dev/host_smoke.sh                # use build/testdata-min (symlinks)
#   tools/dev/host_smoke.sh <project-dir>   # e.g. /path/to/CLANNAD/data
#   SMOKE_REBUILD=1 tools/dev/host_smoke.sh # force a release rebuild first
#
# Environment:
#   CLANNAD_DATA_DIR    source game data dir (default <repo>/data)
#   SMOKE_FRAMES        frames to render before capture (default 180)
#   SMOKE_TIMEOUT       hard watchdog seconds (default 300)
#   SMOKE_WIDTH/HEIGHT  optional window size override
#
# Logs: build/logs/host-smoke.log (tee'd; the log never contains the key)
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_SRC="$REPO_ROOT/engine/siglus_rs"
BUILD_DIR="$REPO_ROOT/build"
LOG_DIR="$BUILD_DIR/logs"
LOG="$LOG_DIR/host-smoke.log"
CAPTURE="$LOG_DIR/host-smoke.png"
MIN_DIR="$BUILD_DIR/testdata-min"
DATA_DIR="${CLANNAD_DATA_DIR:-$REPO_ROOT/data}"
BIN="$BUILD_DIR/engine-host/release/siglus_engine"
FRAMES="${SMOKE_FRAMES:-900}"
WATCHDOG="${SMOKE_TIMEOUT:-300}"
PROJECT_DIR="${1:-${SMOKE_PROJECT_DIR:-$MIN_DIR}}"
# Bounded capture starts directly at the title screen: the normal boot path
# stops on the fiction-disclaimer scene and waits for a click, which a
# headless capture run cannot deliver.
SCENE="${SMOKE_SCENE-_system_title}"

mkdir -p "$LOG_DIR"
: >"$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { say "SMOKE FAIL: $*"; exit 1; }

# --- toolchain (Xcode CLT is not enough for the Rust build) -----------------
export CARGO_HOME="${CARGO_HOME:-$REPO_ROOT/.tools/cargo-home}"
export CARGO_TARGET_DIR="$BUILD_DIR/engine-host"
TC="${RUST_TOOLCHAIN:-$(rustc +nightly --print sysroot)}/bin"
export PATH="$TC:$PATH"
export RUSTC="$TC/rustc"
export RUSTDOC="$TC/rustdoc"

build_engine() {
    say "== building siglus_engine (release) =="
    ( cd "$ENGINE_SRC" && cargo build --release -p siglus_scene_vm --bin siglus_engine ) \
        >>"$LOG" 2>&1 || fail "cargo build failed (see $LOG)"
}

if [[ ! -x "$BIN" || "${SMOKE_REBUILD:-0}" == "1" ]]; then
    build_engine
fi

# --- minimal symlinked project (never copies game files) --------------------
# Required at boot: the encrypted Gameexe/scene pair (for key recovery), the
# key.toml produced by an earlier recovery, plus the asset dirs the title
# scene streams from.  Everything else (koe voice, gan CGs, exe, steam dll,
# savedata) is not needed to reach the title screen.
ensure_min_project() {
    local dir="$1"
    mkdir -p "$dir"
    local entries=()
    # Resource pair + optional pre-recovered key.
    for f in GameexeZH.dat SceneZH.pck Gameexe.dat Scene.pck key.toml; do
        if [[ -e "$DATA_DIR/$f" ]]; then
            ln -sfn "$DATA_DIR/$f" "$dir/$f"
            entries+=("$f")
        fi
    done
    # Asset directories; symlinked as directories, not copied.
    for d in g00 dat bgm wav mov; do
        if [[ -d "$DATA_DIR/$d" ]]; then
            ln -sfn "$DATA_DIR/$d" "$dir/$d"
            entries+=("$d/")
        fi
    done
    say "== minimal project: $dir =="
    say "   symlinked from $DATA_DIR: ${entries[*]}"
    [[ -e "$dir/GameexeZH.dat" || -e "$dir/Gameexe.dat" ]] || fail "no Gameexe*.dat under $DATA_DIR"
    [[ -e "$dir/SceneZH.pck" || -e "$dir/Scene.pck" ]] || fail "no Scene*.pck under $DATA_DIR"
}

if [[ "$PROJECT_DIR" == "$MIN_DIR" ]]; then
    ensure_min_project "$PROJECT_DIR"
fi
[[ -d "$PROJECT_DIR" ]] || fail "project dir not found: $PROJECT_DIR"

# --- run with a hard watchdog (bounded duration) ---------------------------
rm -f "$CAPTURE"
args=(--project-dir "$PROJECT_DIR"
      --capture-png "$CAPTURE"
      --capture-after-frames "$FRAMES"
      --exit-after-capture)
[[ -n "$SCENE" ]] && args+=(--scene-name "$SCENE")
[[ -n "${SMOKE_WIDTH:-}" ]] && args+=(--width "$SMOKE_WIDTH")
[[ -n "${SMOKE_HEIGHT:-}" ]] && args+=(--height "$SMOKE_HEIGHT")

say "== running: RUST_LOG=info $BIN ${args[*]}"
say "   watchdog: ${WATCHDOG}s"
RUST_LOG="${RUST_LOG:-info}" \
    perl -e 'alarm shift; exec @ARGV' "$WATCHDOG" "$BIN" "${args[@]}" 2>&1 | tee -a "$LOG"
status=${PIPESTATUS[0]}
say "== engine exit status: $status"

# --- verdict --------------------------------------------------------------
[[ "$status" -ne 142 ]] || fail "engine exceeded ${WATCHDOG}s watchdog"
grep -Eq "panicked at|thread 'main' panicked" "$LOG" && fail "engine panicked"
grep -Eq "Scene\.pck not found" "$LOG" && fail "scene archive was not resolved"
grep -Eq "no usable Siglus EXE key|could not locate Scene\.pck" "$LOG" && fail "secondary key missing"
[[ "$status" -eq 0 ]] || fail "engine exited $status"
[[ -s "$CAPTURE" ]] || fail "no capture PNG written to $CAPTURE"
size=$(stat -f%z "$CAPTURE" 2>/dev/null || echo 0)
[[ "$size" -gt 8192 ]] || fail "capture PNG is suspiciously small (${size} bytes)"

dims=$(sips -g pixelWidth -g pixelHeight "$CAPTURE" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')
say "== capture: $CAPTURE (${size} bytes, ${dims})"
key_state="missing"
if grep -Eq "recovered and hard-validated a Siglus EXE key|stored recovered Siglus EXE key" "$LOG"; then
    key_state="recovered"
elif [[ -e "$PROJECT_DIR/key.toml" ]]; then
    key_state="key.toml"
fi
say "== secondary key: $key_state"
# Font selection: the zh release requests the MS Gothic family for some
# scenes even though it ships Noto Sans Mono CJK SC in dat/. Landing on that
# shipped Noto font is fine; only the embedded Japanese MS PGothic subset is a
# real problem (missing simplified-Chinese glyphs).
if grep -Eq "configured font .* was not found; using fallback .*NotoSansMonoCJK" "$LOG"; then
    say "== font: shipped NotoSansMonoCJK* in use (CJK glyphs available)"
elif grep -Eq "configured font .* was not found; using fallback .*default\.ttf" "$LOG"; then
    say "== WARNING: embedded MS PGothic fallback in use; Chinese glyphs may be missing"
fi
say "SMOKE OK"
exit 0
