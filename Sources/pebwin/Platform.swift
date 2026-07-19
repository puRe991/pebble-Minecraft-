// The OS surface: window, input, and frame presentation.
//
// Two implementations:
//   • HeadlessPlatform — no window; used in CI and for sim-only runs. Proves the
//     full game loop boots and ticks on this OS without any display.
//   • SDLPlatform (SDLPlatform.swift, behind PEBBLE_SDL) — a real SDL3 window
//     with keyboard/mouse input wired into GameCore. The desktop path.

import Foundation
import PebbleCore

/// Input/window events, already translated to the engine's vocabulary.
/// `code` values are DOM-style key codes ("KeyW", "Space", "ShiftLeft", …) —
/// the same strings GameCore's keybinds use.
enum FrontendEvent {
    case quit
    case key(code: String, down: Bool, ctrlOrCmd: Bool)
    case mouseButton(button: Int, down: Bool)
    case mouseDelta(dx: Double, dy: Double)
    case resize(width: Int, height: Int)
}

protocol Platform: AnyObject {
    /// Drain and translate this frame's OS events.
    func poll() -> [FrontendEvent]
    /// Present the frame the renderer just drew (swap buffers). Headless: no-op.
    func present()
    /// True once the user asked to close the window.
    var shouldClose: Bool { get }
    func shutdown()
}

/// No window — the sim runs to completion and reports. This is the CI path.
final class HeadlessPlatform: Platform {
    func poll() -> [FrontendEvent] { [] }
    func present() {}
    var shouldClose: Bool { false }
    func shutdown() {}
}
