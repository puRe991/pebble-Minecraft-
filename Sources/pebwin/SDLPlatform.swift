// SDLPlatform — the desktop window/input path, built only when PEBBLE_SDL is set
// (and SDL3 dev libraries are on the compiler's search path). Excluded from the
// default build / CI, which have no SDL and run headless.
//
// Two presentation modes:
//   • default (CPU renderer): creates an SDL_Renderer + streaming texture and
//     blits the software framebuffer each frame.
//   • PEBBLE_GPU: creates only the window; GPURenderer claims it for SDL_gpu and
//     draws directly, so present() is a no-op here.
//
// Input (keyboard/mouse) is translated to the engine's vocabulary in both modes.

#if PEBBLE_SDL
import Foundation
import CSDL
import PebbleCore

final class SDLPlatform: Platform {
    let sdlWindow: OpaquePointer
    private var closing = false
    #if !PEBBLE_GPU
    private let sdlRenderer: OpaquePointer
    private let texture: OpaquePointer
    private let rw: Int32 = 480, rh: Int32 = 270   // software render resolution, scaled to the window
    #endif

    init?(width: Int, height: Int, title: String) {
        guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { return nil }
        var flags: SDL_WindowFlags = 0
        #if PEBBLE_GPU
        flags = SDL_WINDOW_VULKAN     // GPU backend claims the window
        #endif
        guard let win = title.withCString({ SDL_CreateWindow($0, Int32(width), Int32(height), flags) }) else {
            SDL_Quit(); return nil
        }
        sdlWindow = win

        #if !PEBBLE_GPU
        guard let ren = SDL_CreateRenderer(win, nil) else {
            SDL_DestroyWindow(win); SDL_Quit(); return nil
        }
        guard let tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGB24,
                                          SDL_TEXTUREACCESS_STREAMING, rw, rh) else {
            SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit(); return nil
        }
        sdlRenderer = ren
        texture = tex
        #endif

        _ = SDL_SetWindowRelativeMouseMode(win, true)   // FPS-style mouse look
    }

    var renderSize: (Int, Int) {
        #if PEBBLE_GPU
        return (0, 0)          // the GPU renderer owns presentation
        #else
        return (Int(rw), Int(rh))
        #endif
    }
    var shouldClose: Bool { closing }

    func poll() -> [FrontendEvent] {
        var out: [FrontendEvent] = []
        var e = SDL_Event()
        while SDL_PollEvent(&e) {
            switch e.type {
            case SDL_EVENT_QUIT.rawValue:
                closing = true; out.append(.quit)
            case SDL_EVENT_KEY_DOWN.rawValue where !e.key.repeat:
                if let c = domCode(e.key.scancode) { out.append(.key(code: c, down: true, ctrlOrCmd: false)) }
            case SDL_EVENT_KEY_UP.rawValue:
                if let c = domCode(e.key.scancode) { out.append(.key(code: c, down: false, ctrlOrCmd: false)) }
            case SDL_EVENT_MOUSE_MOTION.rawValue:
                out.append(.mouseDelta(dx: Double(e.motion.xrel), dy: Double(e.motion.yrel)))
            case SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue:
                out.append(.mouseButton(button: Int(e.button.button), down: true))
            case SDL_EVENT_MOUSE_BUTTON_UP.rawValue:
                out.append(.mouseButton(button: Int(e.button.button), down: false))
            default: break
            }
        }
        return out
    }

    func present(_ frame: RGBFrame) {
        #if !PEBBLE_GPU
        frame.px.withUnsafeBytes { raw in
            _ = SDL_UpdateTexture(texture, nil, raw.baseAddress, rw * 3)
        }
        _ = SDL_RenderClear(sdlRenderer)
        _ = SDL_RenderTexture(sdlRenderer, texture, nil, nil)
        _ = SDL_RenderPresent(sdlRenderer)
        #endif
    }

    func shutdown() {
        #if !PEBBLE_GPU
        SDL_DestroyTexture(texture)
        SDL_DestroyRenderer(sdlRenderer)
        #endif
        SDL_DestroyWindow(sdlWindow)
        SDL_Quit()
    }

    /// SDL3 scancode → DOM-style key code (the strings GameCore's keybinds use).
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
