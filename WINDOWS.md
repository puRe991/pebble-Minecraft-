# Pebble on Windows — porting status & roadmap

Pebble was written as a native **macOS** game (AppKit window, Metal renderer,
AVFoundation audio). This document is the honest state of a Windows port: what
already works, what this change set enables, and what a full playable Windows
build still requires.

**TL;DR:** the *engine* is portable and this change set makes it build off-Apple.
The *game window + renderer + audio* are macOS-native and need a separate
front-end before there is a playable `Pebble.exe`. That front-end is the large,
remaining piece of work.

---

## The two halves of the codebase

Pebble is deliberately split (see [ARCHITECTURE.md](ARCHITECTURE.md)):

| Layer | Target | Depends on | Portable? |
|---|---|---|---|
| **Engine** | `PebbleCore` | Foundation, SQLite, stdlib SIMD | ✅ yes (this change set) |
| **Test harness** | `pebsmoke` | `PebbleCore` only | ✅ yes (this change set) |
| **Game app** | `Pebble` | AppKit, Metal, MetalKit, QuartzCore, AVFoundation, CoreGraphics, ImageIO, Compression | ❌ macOS-only — needs a port |

The engine (`PebbleCore`) is ~90% of the game's *logic*: worldgen, all 100
entity types and their AI, redstone, crafting/enchanting/brewing, physics,
lighting, the section mesher, and SQLite persistence. It has **no AppKit/Metal
imports anywhere** — it talks to the app only through the `GameHost` protocol.
That is what makes it portable.

## What this change set does

It removes the two Apple-only bindings that stopped the *engine* from compiling
off-Apple, without touching the macOS build (both are behind `#if` guards, so the
Apple path is byte-for-byte unchanged):

1. **`simd` → pure-Swift fallback** (`Sources/PebbleCore/Core/MathX.swift`).
   Apple's `simd` module isn't available on Windows/Linux. The engine only used
   a small slice of it (`simd_dot/length/cross/normalize` and a 4×4 float
   matrix), now reimplemented in plain Swift over the stdlib `SIMD` types on
   non-Apple platforms.
2. **`SQLite3` → `CSQLite` system-library shim** (`Sources/CSQLite/`,
   `Sources/PebbleCore/Game/Saves.swift`). Apple ships an `SQLite3` module;
   elsewhere the engine binds the system `libsqlite3` through a small module map.
   The C API is identical, so the persistence code is unchanged.
3. **`Package.swift`** now adds the AppKit/Metal `Pebble` app target **only on
   macOS**, so `swift build` on Windows/Linux compiles just the portable engine
   and the golden test harness.

The save/settings directory already resolves through
`FileManager.applicationSupportDirectory`, which maps to `%APPDATA%\Pebble` on
Windows — no change needed there.

### What you can do after this change set (with a Swift toolchain)

On Windows (with [Swift for Windows](https://www.swift.org/install/windows/) and
a `sqlite3` dev library on the compiler search path, e.g. via vcpkg) or on Linux:

```bash
swift build -c release                          # builds PebbleCore + pebsmoke + pebmap
swift run   -c release pebsmoke                 # runs the 456-check golden suite
swift run   -c release pebmap --seed 4242       # renders a world map → pebble-map-4242.bmp
```

`pebmap` (`Sources/pebmap/`) drives the real worldgen headlessly and writes a
top-down shaded-relief BMP — no window, no Metal, no Apple frameworks. It is the
first thing you can *see* the engine produce off-Apple, and because the engine
is deterministic the same seed yields a byte-identical map on every platform.

> **Verification status:** ✅ verified in CI. The engine builds and the 456-check
> golden suite passes on both **Windows** (windows-latest) and **Linux**, and
> `pebmap` renders a world on each — see the CI runs and the uploaded
> `world-map-windows` / `world-map-linux` artifacts. The macOS build is
> unaffected (both bindings are `#if`-guarded). CI builds in debug for fast
> iteration; a release build (`-c release`) also works and is what you'd ship.

## What a *playable* Windows build still needs

The `Pebble` app target (`Sources/Pebble/`, ~15 files) is a macOS-native shell.
A Windows front-end has to re-implement everything it does. This is the bulk of
the remaining work and needs a Windows machine with a GPU to develop and test.

| Piece | macOS today | Windows replacement (options) | Size |
|---|---|---|---|
| Window, input, event loop | AppKit `NSWindow` + `NSEvent`, `main.swift` | **SDL3** (recommended), GLFW, or Win32 | medium |
| GPU renderer | Metal + `MTKView`, runtime-compiled MSL, 15+ passes (`WorldRenderer`, `Shaders.swift`) | **Direct3D 12** or **Vulkan**; shaders ported from MSL → HLSL/GLSL. A cross-API layer (bgfx, sokol, or wgpu-native) avoids writing D3D and Vulkan twice | **large** |
| Audio synth | `AVAudioSourceNode` 48 kHz callback (`Audio.swift`) | **XAudio2**, WASAPI, or **miniaudio** (portable, single-header) — the synth math itself is portable | small–medium |
| PNG/texture decode | `CoreGraphics` / `ImageIO` | **stb_image** | small |
| Zip / `.mcmeta` pack read | `Compression` (`ResourcePacks.swift`) | **zlib** / **miniz** | small |
| App packaging | `.app` bundle, `codesign` (`pebble` script) | `.exe` + installer (Inno Setup / MSIX); resources beside the exe | small |

The `GameHost` protocol is the clean seam: a Windows front-end implements the
same protocol the macOS app does (open screen, play sound, add particles, upload
meshes, request chunks), and the whole engine drops in unchanged.

### Recommended stack

For the least duplicated effort: **SDL3** (window + input + audio) + a
**cross-platform graphics abstraction** (bgfx or sokol_gfx) so the renderer is
written once and runs on Metal *and* D3D12/Vulkan. That path also keeps the
existing macOS app buildable through the same abstraction later, if desired.

### Rough effort

The engine port (this change set) is a day of cleanup + verification. The
front-end (window/input/audio + porting the 15-pass renderer and its shaders) is
the real project — realistically **several weeks** of focused work for the
renderer alone, since the shading (SSAO, volumetrics, Poisson shadows, ACES,
bloom, the single-draw-call UI canvas) all has to be reproduced.

## Suggested milestones

1. ✅ **Engine compiles off-Apple** — this change set.
2. ✅ **Green test suite on Windows** — the 456-check golden suite passes on
   both Windows and Linux in CI (`.github/workflows/ci.yml`), proving the
   determinism contract holds off-Apple. (The same seed even renders a
   byte-for-byte-equivalent world map on both platforms.)
3. ✅ **Headless world-gen tool** — `pebmap` generates a world and writes a
   top-down BMP. No realtime renderer needed; validates the engine visually on
   Windows. CI renders one each run and uploads it as an artifact.
4. 🚧 **Window + input + audio** via SDL3 — **started.** `pebwin`
   (`Sources/pebwin/`) is the cross-platform front-end. It boots the real engine
   through the `GameHost` seam and runs the game loop. Headless by default (CI
   runs it on Windows/Linux: it creates a world and ticks the full sim — worldgen,
   physics, AI, lighting, meshing — then reports), and opens a real SDL3 window
   with input wired into `GameCore` when built with `PEBBLE_SDL=1`. Audio synth
   and the voxel renderer are the parts still stubbed.
5. **Renderer** — the large piece: implement `Renderer` (`Sources/pebwin/
   Renderer.swift`) on a GPU API. Bring up the mesh/atlas pipeline first (opaque
   pass), then layer on entities, particles, sky, shadows, ultra — mirroring the
   macOS `WorldRenderer` pass order.
6. **Packaging** — `.exe` + installer, resources bundled beside it.

### Building the desktop window

```bash
# Windows: vcpkg install sdl3   ·   Linux: apt install libsdl3-dev   ·   macOS: brew install sdl3
PEBBLE_SDL=1 swift build
PEBBLE_SDL=1 swift run pebwin --window     # opens an SDL3 window, input → the real engine
swift run pebwin --seed 4242 --ticks 200   # headless: boot + tick the sim, no SDL needed
```
