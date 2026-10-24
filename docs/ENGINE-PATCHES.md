# ENGINE-PATCHES — what we changed in the vendored engine

The engine is **siglus_rs** (Rust reimplementation of VisualArt's SiglusEngine),
vendored at `engine/siglus_rs` from <https://github.com/xmoezzz/siglus_rs>,
commit `5f358ef1360b0439e92aed2b749e8f25d8721954` (MPL-2.0, see
`engine/siglus_rs/LICENSE-MPL-2.0`). We keep every local change small, listed
here and marked in the source with a comment. The rest of the app (SwiftUI
shell, tools, docs) is MIT, see `LICENSE`.

Format: file · reason · what changed.

## 1. visionOS is compiled as the UIKit host

`ios_host.rs` is the host-driven FFI used by the app (UIKit/CAMetalLayer +
display link). visionOS uses the same UIKit and Metal APIs, so the module is
enabled there too.

| file | change |
|---|---|
| `crates/siglus_scene_vm/src/ios_host.rs` | `#![cfg(target_os = "ios")]` → `#![cfg(any(target_os = "ios", target_os = "visionos"))]` |
| `crates/siglus_scene_vm/src/lib.rs` | `#[cfg(target_os = "ios")] pub mod ios_host;` → same `any(...)` gate |
| `crates/siglus_scene_vm/src/render/mod.rs` | `new_from_raw_handles` (CAMetalLayer surface) gate gains `target_os = "visionos"` |

`runtime/forms/system.rs` needed no change: its generic fallback already covers
visionOS for the Chihaya benchmark strings.

## 2. `libloading` 0.7.4 vendored for visionOS

`wgpu` 0.20 enables its `vulkan`/GLES dependencies for every target that is
`unix` but not `macos`/`ios` — visionOS is such a target, so `wgpu-hal` pulls
`ash`, which pulls `libloading` 0.7.4. That version has no `RTLD_*` values for
visionOS (it has a `compile_error!` for unknown targets). visionOS is Darwin,
so the macOS/iOS values apply.

| path | change |
|---|---|
| `vendor/libloading-0.7.4/` | copy of libloading 0.7.4 (MIT) |
| `vendor/libloading-0.7.4/src/os/unix/consts.rs` | `target_os = "visionos"` added to the four Darwin `cfg` lists |
| `Cargo.toml` | `[patch.crates-io] libloading = { path = "vendor/libloading-0.7.4" }` |

Patching the tiny loader is deliberately less invasive than forking `wgpu`,
`wgpu-hal` and `wgpu-core` to teach them about visionOS. The unused Vulkan
backend is dead-stripped by the linker; the Metal backend is the one that runs.

## 3. visionOS Metal backend in wgpu / metal-rs

wgpu 0.20 registers its Metal backend only when `target_os` is `macos` or
`ios`. visionOS is neither, so a visionOS build produced a `wgpu::Instance`
with **no backends at all**; `create_surface` then failed with
`Failed to create surface for any enabled backend: {}` and the app could not
start the engine. The vendored copies are the stock crates with
`target_os = "visionos"` added next to the Apple `cfg`s:

| path | change |
|---|---|
| `vendor/wgpu-0.20.1/build.rs` | `metal` cfg alias includes visionOS |
| `vendor/wgpu-core-0.21.1/build.rs` | same alias |
| `vendor/wgpu-core-0.21.1/src/lib.rs` | backend registration + `gfx_if_metal` caller + empty-backend fallback include visionOS |
| `vendor/wgpu-hal-0.21.1/build.rs` | same alias |
| `vendor/wgpu-hal-0.21.1/src/metal/{mod,surface}.rs` | UIKit `RawWindowHandle` accepted; iOS-only layer/scale code also runs on visionOS |
| `vendor/wgpu-hal-0.21.1/Cargo.toml` | `objc`, `block`, `core-graphics-types`, `metal` dependencies also for visionOS |
| `vendor/metal-0.28.0/src/device.rs` | visionOS links `System` instead of `dispatch` (no libdispatch.dylib in the xros SDK) and shares the iOS `MTLCopyAllDevices` exclusion |
| `vendor/block-0.1.6/src/lib.rs` | visionOS links `System` instead of `BlocksRuntime` |
| `vendor/objc-0.2.7/src/message/mod.rs` | visionOS uses the Apple `objc_msgSend` path, not GNUstep `objc_msg_lookup` |
| `Cargo.toml` | `[patch.crates-io]` entries for `wgpu`, `wgpu-core`, `wgpu-hal`, `metal`, `block`, `objc` |

All of it is mechanical `cfg`/link-flag work; no behavioural change on
macOS/iOS. The result: the same CAMetalLayer surface code path runs on
Vision Pro as on iPhone/iPad.

## 4. visionOS audio (cpal / coreaudio)

The engine plays BGM/voices through kira -> cpal.  cpal 0.15 only enables its
CoreAudio host for macOS/iOS, so on visionOS the app fell back to the "null"
host and the log said `kira init failed, audio disabled: Cannot find the
default audio output device`.  visionOS exposes the same CoreAudio/AudioUnit
API, so the vendored copies add `target_os = "visionos"` next to the Apple
`cfg`s:

| path | change |
|---|---|
| `vendor/cpal-0.15.3/src/host/mod.rs` | CoreAudio host also for visionOS |
| `vendor/cpal-0.15.3/src/host/coreaudio/mod.rs` | iOS backend module + `host_time_to_stream_instant` (mach2 is macOS/iOS-only; Apple's timebase is 1:1, so visionOS converts directly) |
| `vendor/cpal-0.15.3/src/platform/mod.rs` | visionOS in the platform gates |
| `vendor/cpal-0.15.3/Cargo.toml` | `coreaudio-rs` and `core-foundation-sys` also for visionOS |
| `vendor/coreaudio-rs-0.11.3/src/audio_unit/{mod,render_callback}.rs` | visionOS treated as iOS |
| `vendor/coreaudio-sys-0.2.17/{build.rs,src/lib.rs}` | xros SDK, `apple-visionos` accepted, bindings enabled |
| `Cargo.toml` | `[patch.crates-io]` entries for `cpal`, `coreaudio-rs`, `coreaudio-sys` |

Verified on the device: the `kira init failed` line is gone and the engine
starts with the same `siglus_ios_create` / Metal surface path.

## 5. CLANNAD-specific engine fixes

CLANNAD's Steam Chinese release ships localized resource names
(`SceneZH.pck`, `GameexeZH.dat`). `GameexeZH.dat` is already in the upstream
Gameexe candidate list; the scene pack resolver and the automatic EXE key
recovery only looked for `Scene.pck`. See:
- `crates/siglus_scene_vm/src/resource.rs` — localized `Scene<LANG>.pck`
  resolution, shared by the VM startup and key recovery
  (details in `docs/ENGINE-NOTES.md`)

## 6. Apple control APIs and modal input (0.1.1)

| file | change |
|---|---|
| `platform/ios/SiglusLauncher/Headers/siglus.h` | Declare keyboard entry points and the read-only `siglus_ios_is_skipping` query; accept visionOS in the UIKit API gate. Swift imports this header directly, retaining the functions under Release dead stripping and checking their C ABI. |
| `crates/siglus_scene_vm/src/ios_host.rs` | Export the skip query, initialize diagnostics, and support opt-in five-second scene/status traces with `SIGLUS_IOS_TRACE_STATUS=1`. Normal gameplay does not enable these traces. |
| `crates/siglus_scene_vm/src/host.rs` | Query skip state without requesting a VM pump; provide focused status diagnostics. |
| `crates/siglus_scene_vm/src/runtime/mod.rs` | Restore host skip's previous configuration; route MWND selection mouse/keyboard input only to the active normal/EXCALL stage namespace so a suspended story choice cannot intercept system-menu input. |
| `crates/siglus_scene_vm/src/vm.rs` | Cover EXCALL child buttons over a suspended story choice. Correct two return-address test fixtures to contain the bytecode offsets those tests use. |

The Apple shell uses visible menu/skip labels and excludes UIKit controls from game
gesture recognition. Its keyboard/controller callbacks run on the main queue, as does
the host's display-link step. The UIKit tests are in `app/Tests` (`ClannadChecks` scheme).

## How the vendored tree is built

Apple hosts also enable native MWND story choices (0.1.2). `runtime/mod.rs`
provides a read-only snapshot and validates a generation plus explicit index;
canvas clicks cannot decide a hidden default option in this mode. Selection
entry stops host skip in `runtime/forms/stage.rs`. `host.rs` and `ios_host.rs`
expose a caller-owned UTF-8 JSON buffer and a selection command through the C
header. The existing `serde_json` dependency is now available on mobile too.
Other engine hosts retain their existing input mode. The Swift panel and its
UIKit tests are in `PlayerChoicePanel.swift` and `PlayerChoicesTests.swift`.
Status diagnostics inspect pending wait flags without calling the mutating
`is_blocked()`/`wait_poll()` path.

`tools/apple/build_engine.sh` builds `game_launcher` (rlib + staticlib) for
every Apple slice with nightly rustc and `-Z build-std` — this machine's rustup
cannot write to `~/.rustup`, so no prebuilt std exists for the Apple targets,
and the tier-3 visionOS targets are not installable at all. The resulting
`libgame_launcher.a` slices are copied to `build/rust/<target>/libSiglus.a` and
assembled into `build/Siglus.xcframework` with the public header
`platform/ios/SiglusLauncher/Headers/siglus.h`.
