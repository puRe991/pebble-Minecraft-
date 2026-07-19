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
swift build -c release            # builds PebbleCore + pebsmoke
swift run   -c release pebsmoke   # runs the 456-check golden suite
```

> **Verification status:** these portability changes have not yet been compiled
> against a real Swift-for-Windows toolchain (none was available in the
> environment they were authored in). They are guard-isolated so the macOS build
> is unaffected; the off-Apple paths follow standard SwiftPM patterns but should
> be treated as *unverified* until someone runs the two commands above. If the
> golden suite prints `456 passed, 0 failed` on Windows, the engine's
> cross-platform determinism is proven end-to-end.

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
2. **Green test suite on Windows** — run `pebsmoke`, confirm `456 passed`.
   Proves the determinism contract holds on Windows.
3. **Headless world-gen tool** — a tiny CLI that generates a world and dumps a
   top-down PNG (via stb_image_write). No realtime renderer needed; validates
   the engine visually on Windows.
4. **Window + input + audio** via SDL3 — a black window that plays sound and
   ticks the sim.
5. **Renderer** — the large piece: bring up the mesh/atlas pipeline first
   (opaque pass), then layer on entities, particles, sky, shadows, ultra.
6. **Packaging** — `.exe` + installer, resources bundled beside it.
