#!/bin/sh
# Build the native visionOS app for Apple Vision Pro (unsigned).
#
#   tools/apple/build_visionos.sh            -> build/Clannad-visionos.ipa
#
# This is the thin visionOS entry point: it checks the Xcode visionOS SDK and
# then runs the visionos branch of build_ipa.sh, which builds the app for
# `generic/platform=visionOS` with code signing disabled and packages it as
#
#   Payload/Clannad.app  ->  build/Clannad-visionos.ipa
#
# Limitations (an unsigned IPA is not directly installable):
#   * An .ipa whose Payload is an unsigned visionOS app cannot be installed
#     as-is.  Vision Pro requires a signed app with a provisioning profile
#     that lists the device.  The reliable path is to open app/Clannad.xcodeproj
#     in Xcode, pick the Vision Pro as the run destination and press Run (a free
#     or paid Apple ID both work; the device must be paired in Xcode > Window >
#     Devices and Simulators and have Developer Mode on).
#   * Sideloading tools that understand visionOS can sign this IPA if they
#     support it; whether that works depends on the tool version, not on this
#     project.  See docs/VALIDATION.md for what was actually tested.
#   * The Vision Pro build is otherwise the same app as the iOS one: same
#     engine, same data import (Finder file sharing is unavailable on
#     visionOS, use the Wi-Fi transfer or AirDrop a folder into Files), and
#     saves stay in <gameRoot>/savedata.
#
# Environment overrides: same as build_ipa.sh (DEVELOPER_DIR, CLANNAD_TEAM,
# CLANNAD_TMPDIR).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if ! xcrun --sdk xros --show-sdk-path > /dev/null 2>&1; then
	echo "error: this Xcode has no visionOS SDK ($DEVELOPER_DIR)" >&2
	echo "       install it in Xcode > Settings > Components, or set DEVELOPER_DIR" >&2
	exit 1
fi

echo "building visionOS (Release, unsigned); result: build/Clannad-visionos.ipa"
# build_ipa.sh already generates the project, builds, fails loudly on
# "error:" lines and packages Payload/Clannad.app.
"$ROOT/tools/apple/build_ipa.sh" visionos

echo ""
echo "Vision Pro 安装：把 app/Clannad.xcodeproj 用 Xcode 打开，选择 Vision Pro 作为运行目标后点 Run。"
echo "未签名的 IPA 不能直接安装；Xcode 会用自己的证书/描述文件签名（免费 Apple ID 同样可用）。"
