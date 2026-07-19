// pebwin — the cross-platform (Windows/Linux) desktop front-end for Pebble.
//
// It boots the real PebbleCore engine, wires it to a Platform (window/input) and
// the CPU voxel renderer (SoftRender.swift), and runs the game loop.
//
//   swift run pebwin                              # headless: boot + tick a world, report
//   swift run pebwin --shot view.bmp --ticks 300  # + render a first-person frame to BMP
//   PEBBLE_SDL=1 swift run pebwin --window         # a real, playable window (needs SDL3)
//
// The headless `--shot` path is what CI uses to prove — with no GPU and no
// display — that a first-person 3-D view of the generated world renders on
// Windows. The SDL window uses the exact same renderer in real time, with WASD +
// mouse wired into the engine, which is what makes it playable on a desktop.

import Foundation
import PebbleCore

// ---- args --------------------------------------------------------------------
var seed = "4242"
var maxTicks = 200
var wantWindow = false
var shotPath: String? = nil
var renderW = 480, renderH = 270
do {
    let a = CommandLine.arguments
    var i = 1
    while i < a.count {
        switch a[i] {
        case "--seed":  if i + 1 < a.count { seed = a[i + 1]; i += 1 }
        case "--ticks": if i + 1 < a.count { maxTicks = Int(a[i + 1]) ?? maxTicks; i += 1 }
        case "--shot":  if i + 1 < a.count { shotPath = a[i + 1]; i += 1 }
        case "--width":  if i + 1 < a.count { renderW = Int(a[i + 1]) ?? renderW; i += 1 }
        case "--height": if i + 1 < a.count { renderH = Int(a[i + 1]) ?? renderH; i += 1 }
        case "--window": wantWindow = true
        case "-h", "--help":
            print("usage: pebwin [--seed S] [--ticks N] [--shot FILE.bmp] [--width W --height H] [--window]")
            exit(0)
        default: break
        }
        i += 1
    }
}

// ---- assemble the front-end --------------------------------------------------
let renderer: Renderer = NullRenderer()   // mesh accounting; the view is raycast
let audio: AudioSink = NullAudio()
let host = FrontendHost(renderer: renderer, audio: audio)

var platform: Platform = HeadlessPlatform()
#if PEBBLE_SDL
if wantWindow {
    if let sdl = SDLPlatform(width: 1280, height: 720, title: "Pebble") {
        platform = sdl
        (renderW, renderH) = sdl.renderSize
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
let game = GameCore()               // registers every block/item/biome/entity/system
game.host = host
game.createWorld(name: "pebwin", seedText: seed, mode: GameMode.survival, difficulty: 2)
print("pebwin: booted overworld (seed \(seed)) on \(platformName()); ticking the real sim…")

let startClock = nowSeconds()
var tick = 0
var frame = RGBFrame(max(1, renderW), max(1, renderH))

func renderAndPresent() {
    guard game.hasWorld(), platform.renderSize.0 > 0 else { return }
    let cam = game.camState(1, timeSec: nowSeconds() - startClock)
    renderWorld(game.world, cam, into: &frame)
    platform.present(frame)
}

func stepOnce() {
    for ev in platform.poll() {
        switch ev {
        case .quit: finish()
        case let .key(code, down, ctrl):
            if down { game.keyDown(code, now: nowSeconds() * 1000, ctrlOrCmd: ctrl) } else { game.keyUp(code) }
        case let .mouseButton(button, down):
            if down { game.mouseDown(button) } else { game.mouseUp(button) }
        case let .mouseDelta(dx, dy): game.mouseDelta(dx, dy)
        case .resize: break
        }
    }

    _ = game.frame(dtMs: 50)
    renderAndPresent()

    tick += 1
    if tick % 20 == 0, let p = game.player {
        print(String(format: "  t=%4d  dim=%@  player=(%.1f, %.1f, %.1f)  sections=%d",
                     tick, "\(game.dim)", p.x, p.y, p.z, renderer.sectionCount))
    }
    if platform.shouldClose || (maxTicks > 0 && tick >= maxTicks && !wantWindow) { finish() }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { stepOnce() }
}

func finish() -> Never {
    // headless screenshot: render one first-person frame of the real world
    if let shot = shotPath, game.hasWorld() {
        var shotFrame = RGBFrame(renderW, renderH)
        game.player?.pitch = 0.32   // tilt slightly down so the landscape frames well
        let cam = game.camState(1, timeSec: nowSeconds() - startClock)
        print(String(format: "pebwin: rendering %d×%d frame from (%.1f, %.1f, %.1f)…",
                     renderW, renderH, cam.x, cam.y, cam.z))
        renderWorld(game.world, cam, into: &shotFrame)
        writeBMP(shot, shotFrame)
        print("pebwin: wrote \(shot)")
    }
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
