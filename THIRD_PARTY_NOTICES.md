# Third-party components and notices

This repository and every release artifact (`Clannad-ios.ipa`,
`Clannad-visionos.ipa`, `Clannad-mac.zip`) contain **no game content**: no
executable, script, image, music, voice, movie or localisation file of
CLANNAD is here, and none is bundled into the application. The game data has
to be imported by the player from a copy they own.

## This project: MIT

The application shell (`app/`), the build and data-import tools (`tools/`) and
the documentation of this repository are released under the **MIT license**
(Copyright (c) 2026 galhack); the full text is in `LICENSE` at the repository
root.

The vendored engine in `engine/siglus_rs/` is **not** relicensed by MIT: it
stays under MPL-2.0 (see below), except separately marked codec modules
whose existing license notices also apply.

## Engine: siglus_rs

| | |
|---|---|
| Project | **siglus_rs** — unofficial full Rust reimplementation of UK2, AVG32, RealLive and SiglusEngine |
| Upstream | <https://github.com/xmoezzz/siglus_rs> |
| Author | xmoezzz and contributors |
| License | **Mozilla Public License 2.0 (MPL-2.0)** |
| License text | `engine/siglus_rs/LICENSE-MPL-2.0` |
| Vendored at | commit **`5f358ef1`** (`engine/siglus_rs/` in this repository) |

The engine source is vendored into this repository (`engine/siglus_rs/`), not
linked as a prebuilt binary, so the complete corresponding source of the
MPL-covered files — including the changes made for this port — is available
here. Files changed for this port keep their MPL-2.0 headers;
the port's build glue (`platform/`, this repository's `tools/`) does not
relicense the engine.

MPL-2.0 is *file-level* copyleft: source files covered by it must remain
available under MPL-2.0 when binaries are distributed, while other files may
use another license. If you redistribute a build made from this repository,
keep the MPL-2.0 source available (for example by pointing at this repository
and the upstream project).

The upstream project describes itself as non-commercial and intended for
research purposes. This port follows that: it is a personal-use project for
players who already own the game.

### Vendored third-party code inside the engine

`engine/siglus_rs/vendor/libloading-0.7.4/` is the **libloading** crate
(MIT/ISC licensed upstream). siglus_rs vendors it and this port added a
one-line `cfg` patch for visionOS; it keeps its upstream license. The port's
engine patches are described in `docs/ENGINE-PATCHES.md`.

## Engine dependencies (high level)

The engine is a Rust workspace and pulls in a number of crates, built
statically into the application. The exact versions and license texts are in
`engine/siglus_rs/Cargo.toml` / `Cargo.lock` and in each crate's `Cargo.toml`
(packaged with the crate). The main ones are:

| Crate | Role |
|---|---|
| `wgpu`, `naga` | GPU abstraction and shader translation (Metal on Apple platforms) |
| `winit` | windowing / event loop glue on desktop |
| `kira` | audio mixing and playback |
| `symphonia`, `lewton` | audio decoding |
| `image`, `png`, `bytemuck` | texture decoding and buffer handling |
| `rodio`, `cpal` | host audio output on desktop |
| `na_wmv_player`, `na_mpeg2_decoder`, `theora-rs`, `oxideav-cinepak` | movie decoding (WMV/OMV and friends) |
| `serde`, `anyhow`, `log`, `env_logger` | data (de)serialisation, error handling and logging |
| `clap` | command-line parsing of the desktop/helper binaries |

Apple compatibility patches to vendored crates are documented in
`docs/ENGINE-PATCHES.md`; their existing licenses remain in place. Exact
license and copyright texts are bundled as `THIRD_PARTY_LICENSES.txt`.

## Embedded font resources

The default fallback is a regular-weight static instance of **Noto Sans SC**,
from https://github.com/notofonts/noto-cjk, licensed under **SIL OFL 1.1**.
Copyright © 2014–2021 Adobe, with Reserved Font Name “Source”. The Noto family
name does not use that reserved name. The upstream commit, input/output SHA-256,
and exact fonttools command are recorded in
`engine/siglus_rs/crates/siglus_scene_vm/assets/fonts/SOURCE.json`; its complete
license is `OFL.txt` in that directory and `OFL-NotoSansSC.txt` in each app.
Legacy MS font names remain lookup aliases only; Microsoft font data is not shipped.
Player-supplied game fonts retain priority.

The UK2 Shinonome bitmap fallback is public domain. The upstream attribution
is recorded at https://plan9port.googlesource.com/plan9/+/master/font/shinonome/README.

## Codec provenance

The WMA Professional modules in `crates/na_wmv_player/src/wma/pro.rs` and
`pro_tables.rs` are explicitly marked **LGPL-2.1-or-later** and follow FFmpeg.
Those notices are preserved; the complete corresponding engine and application
source plus build scripts are supplied so users can modify and relink them.
The Theora rewrite follows libtheora; the Xiph BSD notice is included with
the full third-party texts. These exceptions are not relicensed by the shell MIT license.

## Apple system frameworks

The application uses the frameworks shipped with iOS, iPadOS, visionOS and
macOS (SwiftUI, UIKit, Metal, MetalKit, AVFoundation, CoreMedia, CoreVideo,
CoreAudio, CoreText, Network, QuartzCore, Foundation, …). These are provided by
the operating system and the Xcode SDK and are not redistributed here.

## The game

**CLANNAD** and all of its content — the program, scripts, images, music,
voices, movies, fonts and the official Simplified Chinese resources
(`SceneZH.pck`, `GameexeZH.dat`, `dat/`, `g00/`, `bgm/`, `koe/`, `wav/`,
`mov/`, `gan/`, …) — are copyright © **VisualArt's / Key**. The Steam edition
is published by VisualArt's. "Steam" is a trademark of Valve Corporation.

No part of the game is included in this repository or in the release
artifacts, and none is ever bundled into the application. You need to buy the
game yourself (for example on Steam) and import your own copy; this project
only reads the files a player already has.

This project is not affiliated with, endorsed by, or supported by VisualArt's,
Key, Valve or the siglus_rs maintainers. It is provided **as is**, without
warranty of any kind, for personal use by players who own the game.

## Contact

Author: **galhack** · <galhack@protonmail.com>
