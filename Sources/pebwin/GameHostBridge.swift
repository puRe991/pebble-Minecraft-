// FrontendHost — the single seam between PebbleCore and the desktop front-end.
//
// It implements the engine's `GameHost` protocol: the engine calls these to open
// screens, play sounds, spawn particles, and hand over section meshes. The macOS
// app implements the same protocol against AppKit/Metal/AVFoundation; this
// implementation routes to the portable Renderer/AudioSink seams and otherwise
// no-ops the UI surface (screens/HUD are a later port). Because the whole engine
// talks only through this protocol, the sim runs unchanged behind it.

import PebbleCore

final class FrontendHost: GameHost {
    let renderer: Renderer
    let audio: AudioSink

    init(renderer: Renderer, audio: AudioSink) {
        self.renderer = renderer
        self.audio = audio
    }

    // ---- screens (no UI stack yet — a later milestone) ----
    func hasScreen() -> Bool { false }
    func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) {}
    func openTrading(_ villager: Mob) {}
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}
    func openDeathScreen(_ message: String) { print("[host] you died: \(message)") }
    func openPauseScreen() {}
    func openTitleScreen() {}
    func closeAllScreens() {}
    func releasePointer() {}

    // ---- HUD / chat ----
    func showActionBar(_ text: String, _ time: Int) {}
    func pushChat(_ line: String) { print("[chat] \(line)") }
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}

    // ---- audio ----
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) { audio.play(name) }
    func playUI(_ name: String) { audio.play(name) }
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}

    // ---- particles ----
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {}

    // ---- renderer ----
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        renderer.uploadSection(cx, sy, cz, minY, mesh)
    }
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {
        renderer.removeChunk(cx, cz, sections)
    }
    func clearAllSections() { renderer.clearAll() }
}
