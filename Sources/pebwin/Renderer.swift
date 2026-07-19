// The rendering seam.
//
// PebbleCore does no drawing — it hands finished section meshes to its host via
// `GameHost.uploadMesh`. `FrontendHost` forwards those here. A real Windows
// renderer implements `Renderer` on top of a GPU API (Direct3D 12 or Vulkan, or
// a cross-API layer like bgfx/sokol) and draws the accumulated sections each
// frame, mirroring the macOS `WorldRenderer` pass order. Until that exists, the
// null renderer just counts sections so the headless build has something real to
// report — proof the engine is producing geometry on this platform.

import PebbleCore

protocol Renderer: AnyObject {
    /// A section mesh (opaque/cutout/translucent vertex streams) is ready.
    func uploadSection(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput)
    /// Drop every section of a chunk (it unloaded).
    func removeChunk(_ cx: Int, _ cz: Int, _ sections: Int)
    /// Drop everything (dimension change / world close).
    func clearAll()
    /// Draw one frame from the given interpolated camera. Null renderer: no-op.
    func draw(_ cam: CamState, partial: Double)
    var sectionCount: Int { get }
}

/// Headless renderer: accounts for geometry without a GPU. This is what CI runs.
final class NullRenderer: Renderer {
    private(set) var sectionCount = 0
    private(set) var uploads = 0
    func uploadSection(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        sectionCount += 1
        uploads += 1
    }
    func removeChunk(_ cx: Int, _ cz: Int, _ sections: Int) { sectionCount = max(0, sectionCount - sections) }
    func clearAll() { sectionCount = 0 }
    func draw(_ cam: CamState, partial: Double) {}
}

/// Audio seam. PebbleCore only names sounds (`GameHost.playSound`); the actual
/// real-time synthesizer lives in the macOS app (`Audio.swift`) and is a
/// separate port (it's plain DSP — no Apple frameworks in the math, only the
/// AVAudioSourceNode sink). A desktop build would feed a synth into SDL audio.
protocol AudioSink: AnyObject { func play(_ name: String) }
final class NullAudio: AudioSink { func play(_ name: String) {} }
