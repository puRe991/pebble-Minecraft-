// SDLPlatform — the desktop window/input path, built only when PEBBLE_SDL is set
// (and SDL3 dev libraries are on the compiler's search path). It is intentionally
// excluded from the default build / CI, which have no SDL and run headless.
//
// What it does today: opens a real SDL3 window, captures the mouse, and
// translates keyboard/mouse events into the engine's vocabulary so movement,
// looking, and clicking drive the real GameCore. What it does NOT do yet: draw
// the world — it presents a clear color. The 3D voxel renderer (turning the
// engine's section meshes into pixels via SDL_GPU / Vulkan / D3D12) is the
// remaining milestone; see Renderer.swift and WINDOWS.md.

#if PEBBLE_SDL
import Foundation
import CSDL
import PebbleCore

final class SDLPlatform: Platform {
    private let window: OpaquePointer
    private let renderer: OpaquePointer
    private let texture: OpaquePointer
    private let rw: Int32 = 480, rh: Int32 = 270   // software render resolution, scaled to the window
    private var closing = false

    init?(width: Int, height: Int, title: String) {
        guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { return nil }
        guard let win = title.withCString({ SDL_CreateWindow($0, Int32(width), Int32(height), 0) }) else {
            SDL_Quit(); return nil
        }
        guard let ren = SDL_CreateRenderer(win, nil) else {
            SDL_DestroyWindow(win); SDL_Quit(); return nil
        }
        // a streaming texture the CPU renderer writes into each frame
        guard let tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGB24,
                                          SDL_TEXTUREACCESS_STREAMING, rw, rh) else {
            SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit(); return nil
        }
        window = win
        renderer = ren
        texture = tex
        // relative mouse mode = FPS-style look (raw deltas, cursor hidden)
        _ = SDL_SetWindowRelativeMouseMode(window, true)
    }

    var renderSize: (Int, Int) { (Int(rw), Int(rh)) }
    var shouldClose: Bool { closing }

    func poll() -> [FrontendEvent] {
        var out: [FrontendEvent] = []
        var e = SDL_Event()
        while SDL_PollEvent(&e) {
            switch e.type {
            case SDL_EVENT_QUIT.rawValue:
                closing = true
                out.append(.quit)
            case SDL_EVENT_KEY_DOWN.rawValue where !e.key.repeat:
                if let code = domCode(e.key.scancode) { out.append(.key(code: code, down: true, ctrlOrCmd: false)) }
            case SDL_EVENT_KEY_UP.rawValue:
                if let code = domCode(e.key.scancode) { out.append(.key(code: code, down: false, ctrlOrCmd: false)) }
            case SDL_EVENT_MOUSE_MOTION.rawValue:
                out.append(.mouseDelta(dx: Double(e.motion.xrel), dy: Double(e.motion.yrel)))
            case SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue:
                out.append(.mouseButton(button: Int(e.button.button), down: true))
            case SDL_EVENT_MOUSE_BUTTON_UP.rawValue:
                out.append(.mouseButton(button: Int(e.button.button), down: false))
            default:
                break
            }
        }
        return out
    }

    func present(_ frame: RGBFrame) {
        // upload the CPU framebuffer and blit it scaled to the window
        frame.px.withUnsafeBytes { raw in
            _ = SDL_UpdateTexture(texture, nil, raw.baseAddress, rw * 3)
        }
        _ = SDL_RenderClear(renderer)
        _ = SDL_RenderTexture(renderer, texture, nil, nil)
        _ = SDL_RenderPresent(renderer)
    }

    func shutdown() {
        SDL_DestroyTexture(texture)
        SDL_DestroyRenderer(renderer)
        SDL_DestroyWindow(window)
        SDL_Quit()
    }

    /// SDL3 scancode → DOM-style key code (the strings GameCore's keybinds use).
    /// Only the gameplay-relevant keys; extend as needed.
    private func domCode(_ sc: SDL_Scancode) -> String? {
        switch sc {
        case SDL_SCANCODE_W: return "KeyW"
        case SDL_SCANCODE_A: return "KeyA"
        case SDL_SCANCODE_S: return "KeyS"
        case SDL_SCANCODE_D: return "KeyD"
        case SDL_SCANCODE_E: return "KeyE"
        case SDL_SCANCODE_Q: return "KeyQ"
        case SDL_SCANCODE_F: return "KeyF"
        case SDL_SCANCODE_SPACE: return "Space"
        case SDL_SCANCODE_LSHIFT: return "ShiftLeft"
        case SDL_SCANCODE_LCTRL: return "ControlLeft"
        case SDL_SCANCODE_TAB: return "Tab"
        case SDL_SCANCODE_ESCAPE: return "Escape"
        case SDL_SCANCODE_1: return "Digit1"
        case SDL_SCANCODE_2: return "Digit2"
        case SDL_SCANCODE_3: return "Digit3"
        case SDL_SCANCODE_4: return "Digit4"
        case SDL_SCANCODE_5: return "Digit5"
        case SDL_SCANCODE_6: return "Digit6"
        case SDL_SCANCODE_7: return "Digit7"
        case SDL_SCANCODE_8: return "Digit8"
        case SDL_SCANCODE_9: return "Digit9"
        default: return nil
        }
    }
}
#endif
