// SoftRender — a CPU voxel raycaster.
//
// This is the renderer that makes Pebble *playable* off-Apple without a GPU: for
// each pixel it casts a ray from the camera through the real voxel world (3-D DDA
// over the loaded chunks), finds the first solid block, and shades it by face,
// distance, and block colour. It uses the exact camera basis the macOS Metal
// renderer uses, so you look where the engine thinks you look.
//
// The same buffer it fills is what SDLPlatform streams to the window each frame
// (real-time, interactive) and what `--shot` writes to a BMP — which is how CI
// verifies, headlessly, that a first-person view of the world renders on Windows.
// It is deliberately simple (no textures/shadows yet — that's the GPU port); it
// is, however, a genuine playable 3-D view of the generated world.

import Foundation
import PebbleCore

struct RGBFrame {
    let w: Int, h: Int
    var px: [UInt8]
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt8](repeating: 0, count: w * h * 3) }
    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
        let o = (y * w + x) * 3
        px[o]     = u8(r); px[o + 1] = u8(g); px[o + 2] = u8(b)
    }
}
@inline(__always) private func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v * 255 + 0.5))) }
@inline(__always) private func mix3(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

/// Render a first-person view of `world` from `cam` into `f`.
func renderWorld(_ world: World, _ cam: CamState, into f: inout RGBFrame, maxDist: Int = 96) {
    let W = f.w, H = f.h
    let tanHalf = Foundation.tan(cam.fov * .pi / 180 / 2)
    let aspect = Double(W) / Double(H)

    // camera basis — identical convention to WorldRenderer's `dir`
    let fx = cos(cam.pitch) * -sin(cam.yaw)
    let fy = -sin(cam.pitch)
    let fz = cos(cam.pitch) * cos(cam.yaw)
    // right = normalize(forward × worldUp); up = right × forward
    var rx = fy * 0 - fz * 1, ry = fz * 0 - fx * 0, rz = fx * 1 - fy * 0
    let rl = (rx * rx + ry * ry + rz * rz).squareRoot()
    if rl > 1e-9 { rx /= rl; ry /= rl; rz /= rl }
    let ux = ry * fz - rz * fy
    let uy = rz * fx - rx * fz
    let uz = rx * fy - ry * fx

    let sky = (0.53, 0.68, 0.92)
    let horizon = (0.78, 0.86, 0.96)

    for py in 0..<H {
        let sv = (1 - 2 * (Double(py) + 0.5) / Double(H)) * tanHalf
        for px in 0..<W {
            let su = (2 * (Double(px) + 0.5) / Double(W) - 1) * tanHalf * aspect
            var dx = fx + rx * su + ux * sv
            var dy = fy + ry * su + uy * sv
            var dz = fz + rz * su + uz * sv
            let n = 1 / (dx * dx + dy * dy + dz * dz).squareRoot()
            dx *= n; dy *= n; dz *= n

            if let c = castRay(world, cam.x, cam.y, cam.z, dx, dy, dz, maxDist) {
                f.set(px, py, c.0, c.1, c.2)
            } else {
                let s = mix3(horizon, sky, max(0, min(1, dy * 1.4)))
                f.set(px, py, s.0, s.1, s.2)
            }
        }
    }
}

/// 3-D DDA (Amanatides–Woo). Returns the shaded colour of the first solid full
/// cube hit, or nil for sky.
private func castRay(_ world: World, _ ox: Double, _ oy: Double, _ oz: Double,
                     _ dx: Double, _ dy: Double, _ dz: Double, _ maxDist: Int) -> (Double, Double, Double)? {
    var ix = Int(floor(ox)), iy = Int(floor(oy)), iz = Int(floor(oz))
    let stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1
    let tDX = dx == 0 ? Double.infinity : abs(1 / dx)
    let tDY = dy == 0 ? Double.infinity : abs(1 / dy)
    let tDZ = dz == 0 ? Double.infinity : abs(1 / dz)
    func firstBoundary(_ o: Double, _ i: Int, _ step: Int, _ td: Double) -> Double {
        if td == .infinity { return .infinity }
        let nextEdge = step > 0 ? Double(i + 1) - o : o - Double(i)
        return nextEdge * td
    }
    var tMaxX = firstBoundary(ox, ix, stepX, tDX)
    var tMaxY = firstBoundary(oy, iy, stepY, tDY)
    var tMaxZ = firstBoundary(oz, iz, stepZ, tDZ)

    var axis = 1                // 0=x,1=y,2=z of the face last crossed
    var travelled = 0.0
    let steps = maxDist * 3
    for _ in 0..<steps {
        let id = world.getBlockId(ix, iy, iz)
        if id > 0 && id < blockDefs.count {
            let def = blockDefs[id]
            if def.opaque && def.fullCube {
                let faceShade: Double
                switch axis {
                case 1: faceShade = stepY < 0 ? 1.0 : 0.5   // top bright, bottom dark
                case 2: faceShade = 0.80                    // N/S
                default: faceShade = 0.62                   // E/W
                }
                let fog = max(0, 1 - travelled / Double(maxDist))
                var c = blockColor(id, def)
                let ambient = 0.32
                let lit = ambient + (1 - ambient) * faceShade
                c = (c.0 * lit, c.1 * lit, c.2 * lit)
                // fade to horizon with distance
                let horizon = (0.78, 0.86, 0.96)
                return mix3(horizon, c, fog * 0.85 + 0.15)
            }
        }
        if tMaxX < tMaxY {
            if tMaxX < tMaxZ { ix += stepX; travelled = tMaxX; tMaxX += tDX; axis = 0 }
            else { iz += stepZ; travelled = tMaxZ; tMaxZ += tDZ; axis = 2 }
        } else {
            if tMaxY < tMaxZ { iy += stepY; travelled = tMaxY; tMaxY += tDY; axis = 1 }
            else { iz += stepZ; travelled = tMaxZ; tMaxZ += tDZ; axis = 2 }
        }
    }
    return nil
}

/// A representative colour per block, keyed by name (extendable). The GPU port
/// replaces this with the real texture atlas; a flat colour is enough to make the
/// world legible and playable now.
private func blockColor(_ id: Int, _ def: BlockDef) -> (Double, Double, Double) {
    let n = def.name
    func has(_ s: String) -> Bool { n.contains(s) }
    if has("grass_block") || n == "grass"          { return (0.36, 0.55, 0.26) }
    if has("leaves") || has("vine") || has("moss")  { return (0.24, 0.45, 0.20) }
    if has("water")                                 { return (0.20, 0.38, 0.70) }
    if has("lava") || has("magma")                  { return (0.86, 0.40, 0.12) }
    if has("sand") && !has("sandstone")             { return (0.83, 0.78, 0.56) }
    if has("sandstone")                             { return (0.80, 0.74, 0.55) }
    if has("dirt") || has("mud") || has("clay") || has("podzol") || has("rooted") { return (0.47, 0.34, 0.22) }
    if has("gravel")                                { return (0.50, 0.48, 0.47) }
    if has("deepslate") || has("blackstone") || has("basalt") { return (0.24, 0.24, 0.27) }
    if has("snow") || has("powder")                 { return (0.94, 0.96, 0.99) }
    if has("ice")                                   { return (0.62, 0.75, 0.92) }
    if has("netherrack")                            { return (0.42, 0.16, 0.16) }
    if has("end_stone")                             { return (0.87, 0.86, 0.62) }
    if has("log") || has("wood") || has("stem") || has("planks") { return (0.51, 0.38, 0.23) }
    if has("stone") || has("andesite") || has("diorite") || has("granite") || has("tuff") || has("cobble") { return (0.50, 0.50, 0.52) }
    if has("ore")                                   { return (0.48, 0.48, 0.50) }
    if has("terracotta")                            { return (0.60, 0.36, 0.24) }
    if has("wool") || has("concrete")               { return (0.72, 0.72, 0.74) }
    // fallback: a stable muted colour from the id hash
    let h = mix32(UInt32(id) &* 2654435761)
    return (0.35 + Double(h & 0xff) / 255 * 0.4,
            0.35 + Double((h >> 8) & 0xff) / 255 * 0.4,
            0.35 + Double((h >> 16) & 0xff) / 255 * 0.4)
}

/// Write a 24-bit BMP (no compression → no zlib dependency).
func writeBMP(_ path: String, _ f: RGBFrame) {
    let w = f.w, h = f.h
    let rowSize = ((w * 3 + 3) / 4) * 4
    let imgSize = rowSize * h
    var d = Data(capacity: 54 + imgSize)
    func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(0x42); d.append(0x4D)
    u32(54 + imgSize); u16(0); u16(0); u32(54)
    u32(40); u32(w); u32(h); u16(1); u16(24); u32(0); u32(imgSize); u32(2835); u32(2835); u32(0); u32(0)
    let pad = rowSize - w * 3
    for row in stride(from: h - 1, through: 0, by: -1) {
        for x in 0..<w {
            let o = (row * w + x) * 3
            d.append(f.px[o + 2]); d.append(f.px[o + 1]); d.append(f.px[o])
        }
        for _ in 0..<pad { d.append(0) }
    }
    try? d.write(to: URL(fileURLWithPath: path))
}
