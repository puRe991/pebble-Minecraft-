// GPURenderer — a GPU backend skeleton on SDL3's GPU API (SDL_gpu), which targets
// Vulkan, Direct3D 12 and Metal from one code path. Built only with PEBBLE_GPU
// (which implies PEBBLE_SDL). This is the scaffold for the "real" renderer: it
// wires up the device, a graphics pipeline over the engine's 28-byte vertex
// format, per-section GPU buffers fed from GameHost.uploadMesh, a depth buffer,
// and a per-frame view-projection uniform, then draws every section.
//
// Status: this compiles against SDL_gpu (verified in CI with SDL3 built from
// source, PEBBLE_GPU=1). It needs a GPU + display to actually run, and it needs
// the shaders compiled to the backend's bytecode — see Sources/pebwin/shaders/.
// It is intentionally minimal (flat lighting, one pipeline, no cutout/translucent
// sorting yet); it is the structural starting point, not the finished renderer.

#if PEBBLE_GPU
import Foundation
import CSDL
import PebbleCore

/// One section's GPU-resident geometry.
private struct SectionMesh {
    var vbuf: OpaquePointer     // SDL_GPUBuffer (vertices, 28B stride)
    var ibuf: OpaquePointer     // SDL_GPUBuffer (uint32 indices)
    var indexCount: Int
    var origin: (Float, Float, Float)   // section world origin, added in the shader
}

final class GPURenderer: Renderer {
    private let device: OpaquePointer
    private let window: OpaquePointer
    private var pipeline: OpaquePointer?
    private var depthTexture: OpaquePointer?
    private var depthW: Int32 = 0, depthH: Int32 = 0
    private var sections: [SectionPos: SectionMesh] = [:]
    private(set) var sectionCount = 0

    struct SectionPos: Hashable { let cx: Int, sy: Int, cz: Int }

    init?(window: OpaquePointer) {
        // SPIRV covers Vulkan; SDL translates to D3D12/Metal where needed.
        guard let dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, nil) else { return nil }
        guard SDL_ClaimWindowForGPUDevice(dev, window) else { SDL_DestroyGPUDevice(dev); return nil }
        device = dev
        self.window = window
        buildPipeline()
    }

    // MARK: pipeline ---------------------------------------------------------

    private func loadShader(_ file: String, stage: SDL_GPUShaderStage, uniformBuffers: UInt32) -> OpaquePointer? {
        // shaders live beside the executable as compiled SPIR-V (see shaders/README)
        var size = 0
        guard let code = SDL_LoadFile(file, &size) else {
            print("gpu: missing shader \(file) — compile the GLSL in Sources/pebwin/shaders to SPIR-V")
            return nil
        }
        defer { SDL_free(code) }
        var info = SDL_GPUShaderCreateInfo()
        info.code = code.assumingMemoryBound(to: UInt8.self)
        info.code_size = size
        info.entrypoint = "main"
        info.format = SDL_GPU_SHADERFORMAT_SPIRV
        info.stage = stage
        info.num_uniform_buffers = uniformBuffers
        return SDL_CreateGPUShader(device, &info)
    }

    private func buildPipeline() {
        guard let vs = loadShader("section.vert.spv", stage: SDL_GPU_SHADERSTAGE_VERTEX, uniformBuffers: 1),
              let fs = loadShader("section.frag.spv", stage: SDL_GPU_SHADERSTAGE_FRAGMENT, uniformBuffers: 0) else {
            return
        }
        defer { SDL_ReleaseGPUShader(device, vs); SDL_ReleaseGPUShader(device, fs) }

        // vertex layout: float3 pos @0, float2 uv @12, uint A @20, uint B @24 (stride 28)
        var attrs = [
            SDL_GPUVertexAttribute(location: 0, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, offset: 0),
            SDL_GPUVertexAttribute(location: 1, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 12),
            SDL_GPUVertexAttribute(location: 2, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_UINT,   offset: 20),
            SDL_GPUVertexAttribute(location: 3, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_UINT,   offset: 24),
        ]
        var vbDesc = SDL_GPUVertexBufferDescription(
            slot: 0, pitch: 28, input_rate: SDL_GPU_VERTEXINPUTRATE_VERTEX, instance_step_rate: 0)

        attrs.withUnsafeMutableBufferPointer { ap in
            withUnsafeMutablePointer(to: &vbDesc) { vb in
                var target = SDL_GPUColorTargetDescription()
                target.format = SDL_GetGPUSwapchainTextureFormat(device, window)

                withUnsafeMutablePointer(to: &target) { tp in
                    var info = SDL_GPUGraphicsPipelineCreateInfo()
                    info.vertex_shader = vs
                    info.fragment_shader = fs
                    info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
                    info.vertex_input_state = SDL_GPUVertexInputState(
                        vertex_buffer_descriptions: vb, num_vertex_buffers: 1,
                        vertex_attributes: ap.baseAddress, num_vertex_attributes: 4)
                    info.rasterizer_state.cull_mode = SDL_GPU_CULLMODE_BACK
                    info.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE
                    info.depth_stencil_state.enable_depth_test = true
                    info.depth_stencil_state.enable_depth_write = true
                    info.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_LESS
                    info.target_info.color_target_descriptions = tp
                    info.target_info.num_color_targets = 1
                    info.target_info.depth_stencil_format = SDL_GPU_TEXTUREFORMAT_D24_UNORM
                    info.target_info.has_depth_stencil_target = true
                    pipeline = SDL_CreateGPUGraphicsPipeline(device, &info)
                }
            }
        }
        if pipeline == nil { print("gpu: pipeline creation failed") }
    }

    // MARK: mesh upload (Renderer protocol) ----------------------------------

    private func makeBuffer(_ usage: SDL_GPUBufferUsageFlags, _ bytes: UnsafeRawPointer, _ size: Int) -> OpaquePointer? {
        var bi = SDL_GPUBufferCreateInfo(usage: usage, size: UInt32(size), props: 0)
        guard let buf = SDL_CreateGPUBuffer(device, &bi) else { return nil }
        var ti = SDL_GPUTransferBufferCreateInfo(
            usage: SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, size: UInt32(size), props: 0)
        guard let tb = SDL_CreateGPUTransferBuffer(device, &ti) else { SDL_ReleaseGPUBuffer(device, buf); return nil }
        if let map = SDL_MapGPUTransferBuffer(device, tb, false) {
            memcpy(map, bytes, size)
            SDL_UnmapGPUTransferBuffer(device, tb)
        }
        if let cmd = SDL_AcquireGPUCommandBuffer(device), let pass = SDL_BeginGPUCopyPass(cmd) {
            var src = SDL_GPUTransferBufferLocation(transfer_buffer: tb, offset: 0)
            var dst = SDL_GPUBufferRegion(buffer: buf, offset: 0, size: UInt32(size))
            SDL_UploadToGPUBuffer(pass, &src, &dst, false)
            SDL_EndGPUCopyPass(pass)
            _ = SDL_SubmitGPUCommandBuffer(cmd)
        }
        SDL_ReleaseGPUTransferBuffer(device, tb)
        return buf
    }

    func uploadSection(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        // skeleton draws the opaque layer only
        let layer = mesh.opaque
        let key = SectionPos(cx: cx, sy: sy, cz: cz)
        removeSection(key)
        guard !layer.idx.isEmpty, !layer.data.isEmpty else { return }

        var vbuf: OpaquePointer?
        var ibuf: OpaquePointer?
        layer.data.withUnsafeBytes { vb in
            vbuf = makeBuffer(SDL_GPU_BUFFERUSAGE_VERTEX, vb.baseAddress!, vb.count)
        }
        layer.idx.withUnsafeBytes { ib in
            ibuf = makeBuffer(SDL_GPU_BUFFERUSAGE_INDEX, ib.baseAddress!, ib.count)
        }
        guard let v = vbuf, let i = ibuf else { return }
        sections[key] = SectionMesh(vbuf: v, ibuf: i, indexCount: layer.idx.count,
                                    origin: (Float(cx * 16), Float(minY + sy * 16), Float(cz * 16)))
        sectionCount = sections.count
    }

    private func removeSection(_ key: SectionPos) {
        if let m = sections.removeValue(forKey: key) {
            SDL_ReleaseGPUBuffer(device, m.vbuf)
            SDL_ReleaseGPUBuffer(device, m.ibuf)
        }
    }

    func removeChunk(_ cx: Int, _ cz: Int, _ sectionsPerChunk: Int) {
        for key in sections.keys where key.cx == cx && key.cz == cz { removeSection(key) }
        sectionCount = sections.count
    }

    func clearAll() {
        for key in Array(sections.keys) { removeSection(key) }
        sectionCount = 0
    }

    // MARK: draw -------------------------------------------------------------

    func draw(_ cam: CamState, partial: Double) {
        guard let pipeline, let cmd = SDL_AcquireGPUCommandBuffer(device) else { return }
        var swap: OpaquePointer?
        var w: UInt32 = 0, h: UInt32 = 0
        guard SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swap, &w, &h), let swapTex = swap else {
            _ = SDL_SubmitGPUCommandBuffer(cmd); return
        }
        ensureDepth(Int32(w), Int32(h))

        var color = SDL_GPUColorTargetInfo()
        color.texture = swapTex
        color.clear_color = SDL_FColor(r: 0.53, g: 0.68, b: 0.92, a: 1)
        color.load_op = SDL_GPU_LOADOP_CLEAR
        color.store_op = SDL_GPU_STOREOP_STORE

        var depth = SDL_GPUDepthStencilTargetInfo()
        depth.texture = depthTexture
        depth.clear_depth = 1
        depth.load_op = SDL_GPU_LOADOP_CLEAR
        depth.store_op = SDL_GPU_STOREOP_DONT_CARE

        let viewProj = makeViewProj(cam, aspect: Float(w) / Float(max(1, h)))

        withUnsafePointer(to: &color) { cp in
            let pass = SDL_BeginGPURenderPass(cmd, cp, 1, &depth)
            SDL_BindGPUGraphicsPipeline(pass, pipeline)
            for m in sections.values {
                var uni = Uniforms(viewProj: viewProj, origin: m.origin, pad: 0)
                SDL_PushGPUVertexUniformData(cmd, 0, &uni, UInt32(MemoryLayout<Uniforms>.size))
                var vb = SDL_GPUBufferBinding(buffer: m.vbuf, offset: 0)
                SDL_BindGPUVertexBuffers(pass, 0, &vb, 1)
                var ib = SDL_GPUBufferBinding(buffer: m.ibuf, offset: 0)
                SDL_BindGPUIndexBuffer(pass, &ib, SDL_GPU_INDEXELEMENTSIZE_32BIT)
                SDL_DrawGPUIndexedPrimitives(pass, UInt32(m.indexCount), 1, 0, 0, 0)
            }
            SDL_EndGPURenderPass(pass)
        }
        _ = SDL_SubmitGPUCommandBuffer(cmd)
    }

    private struct Uniforms { var viewProj: (Float, Float, Float, Float, Float, Float, Float, Float,
                                             Float, Float, Float, Float, Float, Float, Float, Float)
                              var origin: (Float, Float, Float); var pad: Float }

    private func ensureDepth(_ w: Int32, _ h: Int32) {
        if depthTexture != nil && depthW == w && depthH == h { return }
        if let d = depthTexture { SDL_ReleaseGPUTexture(device, d) }
        var ti = SDL_GPUTextureCreateInfo()
        ti.type = SDL_GPU_TEXTURETYPE_2D
        ti.format = SDL_GPU_TEXTUREFORMAT_D24_UNORM
        ti.usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET
        ti.width = UInt32(w); ti.height = UInt32(h)
        ti.layer_count_or_depth = 1; ti.num_levels = 1
        depthTexture = SDL_CreateGPUTexture(device, &ti)
        depthW = w; depthH = h
    }

    /// column-major view-projection, matching MathX's Metal-convention helpers.
    private func makeViewProj(_ cam: CamState, aspect: Float) -> (Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float) {
        let proj = mat4Perspective(fovYRad: Float(cam.fov * .pi / 180), aspect: aspect, near: 0.05, far: 512)
        let dir = SIMD3<Float>(Float(cos(cam.pitch) * -sin(cam.yaw)),
                               Float(-sin(cam.pitch)),
                               Float(cos(cam.pitch) * cos(cam.yaw)))
        let view = mat4LookDir(eye: SIMD3<Float>(Float(cam.x), Float(cam.y), Float(cam.z)),
                               dir: dir, up: SIMD3<Float>(0, 1, 0))
        let m = proj * view
        return (m[0][0], m[0][1], m[0][2], m[0][3],
                m[1][0], m[1][1], m[1][2], m[1][3],
                m[2][0], m[2][1], m[2][2], m[2][3],
                m[3][0], m[3][1], m[3][2], m[3][3])
    }
}
#endif
