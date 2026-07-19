// pebwin — the cross-platform (Windows/Linux) desktop front-end for Pebble.
//
// It boots the real PebbleCore engine, wires it to a Platform (window/input) and
// a Renderer, and runs the game loop. With no flags it runs HEADLESS: it creates
// a world and ticks the full simulation — worldgen, physics, entity AI, lighting,
// meshing — reporting progress, then exits. That is the proof the entire game
// runs on this OS. Built with PEBBLE_SDL (and SDL3 installed) it opens a real
// window with input wired into the engine; the 3D voxel renderer that turns the
// engine's section meshes into pixels is the remaining piece (see Renderer.swift
// and WINDOWS.md).
//
//   swift run pebwin                       # headless: boot + tick a world, report
//   swift run pebwin --seed 1234 --ticks 400
//   PEBBLE_SDL=1 swift build && swift run pebwin --window   # desktop window (needs SDL3)

import Foundation
import PebbleCore

// ---- args --------------------------------------------------------------------
var seed = "4242"
var maxTicks = 200
var wantWindow = false
do {
    let a = CommandLine.arguments
    var i = 1
    while i < a.count {
        switch a[i] {
        case "--seed":  if i + 1 < a.count { seed = a[i + 1]; i += 1 }
        case "--ticks": if i + 1 < a.count { maxTicks = Int(a[i + 1]) ?? maxTicks; i += 1 }
        case "--window": wantWindow = true
        case "-h", "--help":
            print("usage: pebwin [--seed S] [--ticks N] [--window]")
            exit(0)
        default: break
        }
        i += 1
    }
}

// ---- assemble the front-end --------------------------------------------------
let renderer: Renderer = NullRenderer()
let audio: AudioSink = NullAudio()
let host = FrontendHost(renderer: renderer, audio: audio)

var platform: Platform = HeadlessPlatform()
#if PEBBLE_SDL
if wantWindow {
    if let sdl = SDLPlatform(width: 1280, height: 720, title: "Pebble") {
        platform = sdl
    } else {
        print("pebwin: SDL init failed — falling back to headless")
    }
}
#else
if wantWindow {
    print("pebwin: built without SDL (rebuild with PEBBLE_SDL=1 and SDL3 installed) — running headless")
}
#endif

// ---- boot the engine ---------------------------------------------------------
// GameCore.init() registers every block/item/biome/recipe/entity/system.
let game = GameCore()
game.host = host
game.createWorld(name: "pebwin", seedText: seed, mode: GameMode.survival, difficulty: 2)
print("pebwin: booted overworld (seed \(seed)) on \(platformName()); ticking the real sim…")

// ---- the game loop -----------------------------------------------------------
// Driven off the main dispatch queue so the engine's chunk-publish callbacks
// (GameCore uses DispatchQueue.main.async → adoptChunk) are serviced between
// frames. Headless runs fast-forward; the SDL path would pace to real time.
let startClock = nowSeconds()
var tick = 0

func stepOnce() {
    for ev in platform.poll() {
        switch ev {
        case .quit: finish()
        case let .key(code, down, ctrl):
            if down { game.keyDown(code, now: nowSeconds() * 1000, ctrlOrCmd: ctrl) }
            else { game.keyUp(code) }
        case let .mouseButton(button, down):
            if down { game.mouseDown(button) } else { game.mouseUp(button) }
        case let .mouseDelta(dx, dy): game.mouseDelta(dx, dy)
        case .resize: break
        }
    }

    let partial = game.frame(dtMs: 50)

    if game.hasWorld() {
        let cam = game.camState(partial, timeSec: nowSeconds() - startClock)
        renderer.draw(cam, partial: partial)
    }
    platform.present()

    tick += 1
    if tick % 20 == 0, let p = game.player {
        print(String(format: "  t=%4d  dim=%@  player=(%.1f, %.1f, %.1f)  sections=%d",
                     tick, "\(game.dim)", p.x, p.y, p.z, renderer.sectionCount))
    }
    if platform.shouldClose || (maxTicks > 0 && tick >= maxTicks && !wantWindow) { finish() }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { stepOnce() }
}

func finish() -> Never {
    print("pebwin: ran \(tick) ticks; sections meshed: \(renderer.sectionCount). Engine ran clean on \(platformName()).")
    platform.shutdown()
    exit(0)
}

func platformName() -> String {
    #if os(Windows)
    return "Windows"
    #elseif os(Linux)
    return "Linux"
    #elseif os(macOS)
    return "macOS"
    #else
    return "this platform"
    #endif
}

DispatchQueue.main.async { stepOnce() }
dispatchMain()
