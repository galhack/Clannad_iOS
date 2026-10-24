#!/bin/bash
# Build the vendored SiglusEngine reimplementation (engine/siglus_rs) for every
# Apple platform we ship and assemble build/Siglus.xcframework.
#
#   tools/apple/build_engine.sh                 # all device slices (fast path)
#   tools/apple/build_engine.sh --with-intel-mac  # also x86_64 Mac Catalyst
#   tools/apple/build_engine.sh --targets aarch64-apple-ios
#
# Why nightly + `-Z build-std`:
#   Building std from the installed `rust-src` component gives one path for
#   every Apple target, including the tier-3
#   `aarch64-apple-visionos` / `aarch64-apple-visionos-sim` targets.
#
# Requirements: Xcode with the iOS, macOS and visionOS SDKs; nightly rustc with
# the `rust-src` component; no network beyond the first cargo download.
#
# Environment overrides:
#   DEVELOPER_DIR   Xcode to use (default /Applications/Xcode.app/Contents/Developer)
#   CARGO_HOME      cargo home (default $ROOT/.tools/cargo-home, kept out of git)
#   RUST_TOOLCHAIN  toolchain directory (default: the installed nightly)
#   JOBS            parallel rustc jobs (passed to cargo -j)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/engine/siglus_rs"
OUT="$ROOT/build/rust"
XC="$ROOT/build/Siglus.xcframework"
HEADERS="$ROOT/engine/siglus_rs/platform/ios/SiglusLauncher/Headers"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CARGO_HOME="${CARGO_HOME:-$ROOT/.tools/cargo-home}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/build/rust-target}"
mkdir -p "$CARGO_HOME"

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-$(rustc +nightly --print sysroot)}"
if [ ! -x "$RUST_TOOLCHAIN/bin/cargo" ]; then
	# Fall back to whatever nightly rustup has on PATH.
	RUST_TOOLCHAIN="$(dirname "$(dirname "$(command -v rustc)")")"
fi
TC_BIN="$RUST_TOOLCHAIN/bin"
export PATH="$TC_BIN:$PATH"
export RUSTC="$TC_BIN/rustc"
export RUSTDOC="$TC_BIN/rustdoc"

WITH_INTEL_MAC=0
TARGETS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--with-intel-mac) WITH_INTEL_MAC=1; shift ;;
	--targets) TARGETS+=($2); shift 2 ;;
	-h | --help) sed -n '2,30p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
	TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-ios-macabi aarch64-apple-visionos aarch64-apple-visionos-sim)
	[ "$WITH_INTEL_MAC" = 1 ] && TARGETS+=(x86_64-apple-ios-macabi)
fi

sdk_for() {
	case "$1" in
	aarch64-apple-ios | x86_64-apple-ios) echo iphoneos ;;
	aarch64-apple-ios-sim) echo iphonesimulator ;;
	*-apple-ios-macabi) echo macosx ;;
	aarch64-apple-visionos) echo xros ;;
	aarch64-apple-visionos-sim) echo xrsimulator ;;
	*) echo "" ;;
	esac
}

deploy_for() {
	case "$1" in
	*-apple-ios-macabi) echo 17.0 ;;
	aarch64-apple-ios | aarch64-apple-ios-sim) echo 17.0 ;;
	aarch64-apple-visionos | aarch64-apple-visionos-sim) echo 1.0 ;;
	*) echo "" ;;
	esac
}

build_target() {
	local tgt="$1" sdk dep sdkroot
	local cargo_args=(-Z build-std=std,panic_abort --target "$tgt" --release -p game_launcher --lib)
	if [ -n "${JOBS:-}" ]; then
		cargo_args+=(-j "$JOBS")
	fi
	sdk="$(sdk_for "$tgt")"
	dep="$(deploy_for "$tgt")"
	[ -n "$sdk" ] || { echo "error: unknown target $tgt" >&2; return 1; }
	sdkroot="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk "$sdk" --show-sdk-path)"

	# cc-rs / bindgen build scripts read these; the C shims (ring) and
	# coreaudio-sys need the SDK and the deployment target of *this* slice.
	case "$sdk" in
	xros)
		export SDKROOT="$sdkroot" XROS_DEPLOYMENT_TARGET="${XROS_DEPLOYMENT_TARGET:-$dep}" ;;
	xrsimulator)
		export SDKROOT="$sdkroot" XROS_DEPLOYMENT_TARGET="${XROS_DEPLOYMENT_TARGET:-$dep}" ;;
	iphoneos | iphonesimulator)
		export SDKROOT="$sdkroot" IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-$dep}" ;;
	macosx)
		export SDKROOT="$sdkroot" MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$dep}"
		# coreaudio-sys 0.2.17 has `unreachable!()` for *-apple-ios-macabi;
		# it honours COREAUDIO_SDK_PATH before its own target table.
		if [ "$tgt" = "aarch64-apple-ios-macabi" ] || [ "$tgt" = "x86_64-apple-ios-macabi" ]; then
			export COREAUDIO_SDK_PATH="$sdkroot"
		fi ;;
	esac
	[ "$sdk" = "macosx" ] || unset COREAUDIO_SDK_PATH

	echo "==> $tgt (sdk=$sdk sdkroot=$sdkroot)"
	(
		cd "$ENGINE"
		cargo build "${cargo_args[@]}"
	)
}

for tgt in "${TARGETS[@]}"; do
	build_target "$tgt"
	lib="$CARGO_TARGET_DIR/$tgt/release/libgame_launcher.a"
	[ -f "$lib" ] || { echo "error: missing $lib" >&2; exit 1; }
	mkdir -p "$OUT/$tgt"
	cp -f "$lib" "$OUT/$tgt/libSiglus.a"
done

# Assemble the XCFramework from the slices that exist.
rm -rf "$XC"
CREATE=()
add_slice() {
	local tgt="$1"
	local lib="$OUT/$tgt/libSiglus.a"
	[ -f "$lib" ] || return 0
	CREATE+=(-library "$lib" -headers "$HEADERS")
}
add_slice aarch64-apple-ios
add_slice aarch64-apple-ios-sim
# Catalyst: a single xcframework slice must be fat when both arches exist.
if [ -f "$OUT/x86_64-apple-ios-macabi/libSiglus.a" ]; then
	mkdir -p "$OUT/macos-maccatalyst"
	lipo -create \
		"$OUT/aarch64-apple-ios-macabi/libSiglus.a" \
		"$OUT/x86_64-apple-ios-macabi/libSiglus.a" \
		-output "$OUT/macos-maccatalyst/libSiglus.a"
	CREATE+=(-library "$OUT/macos-maccatalyst/libSiglus.a" -headers "$HEADERS")
else
	add_slice aarch64-apple-ios-macabi
fi
add_slice aarch64-apple-visionos
add_slice aarch64-apple-visionos-sim

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework "${CREATE[@]}" -output "$XC" >/dev/null
echo "wrote ${XC#$ROOT/}"
for s in "$XC"/*; do
	[ -d "$s" ] && echo "  $(basename "$s"): $(lipo -info "$s"/libSiglus.a 2>/dev/null | sed 's/^.*: //')"
done
