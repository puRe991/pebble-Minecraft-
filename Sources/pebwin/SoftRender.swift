// SoftRender — a CPU voxel raycaster with texture-atlas sampling.
//
// For each pixel it casts a ray through the real voxel world (3-D DDA), finds the
// first solid block, works out which face it hit and where, looks up that face's
// atlas tile (the engine's TILE_TABLE), samples the tile, and shades it by face,
// biome tint, and distance. It uses the exact camera basis the macOS Metal
// renderer uses. The same buffer feeds the SDL window (real-time) and `--shot`
// (which CI renders headlessly to verify a textured first-person view on Windows).

import Foundation
import PebbleCore

struct RGBFrame {
    let w: Int, h: Int
    var px: [UInt8]
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt8](repeating: 0, count: w * h * 3) }
    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
        let o = (y * w + x) * 3
        px[o] = u8(r); px[o + 1] = u8(g); px[o + 2] = u8(b)
    }
}
// air-neighbour offset per face (0=-y 1=+y 2=-z 3=+z 4=-x 5=+x) — where the
// light that illuminates that face lives.
private let FACE_OFF: [(Int, Int, Int)] = [(0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)]

@inline(__always) private func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v * 255 + 0.5))) }
@inline(__always) private func frac(_ x: Double) -> Double { x - x.rounded(.down) }
@inline(__always) private func mix3(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

func renderWorld(_ world: World, _ cam: CamState, _ atlas: Atlas, into f: inout RGBFrame, maxDist: Int = 96) {
    let W = f.w, H = f.h
    let tanHalf = Foundation.tan(cam.fov * .pi / 180 / 2)
    let aspect = Double(W) / Double(H)

    let fx = cos(cam.pitch) * -sin(cam.yaw)
    let fy = -sin(cam.pitch)
    let fz = cos(cam.pitch) * cos(cam.yaw)
    var rx = -fz, ry = 0.0, rz = fx          // forward × worldUp
    let rl = (rx * rx + ry * ry + rz * rz).squareRoot()
    if rl > 1e-9 { rx /= rl; ry /= rl; rz /= rl }
    let ux = ry * fz - rz * fy
    let uy = rz * fx - rx * fz
    let uz = rx * fy - ry * fx

    // sky colour by time of day: day blue ↔ warm twilight ↔ night navy.
    // (skyDarken is 0 at noon … 11 at night; the engine's own value.)
    let dayF = max(0, min(1, 1 - world.skyDarken() / 11))
    let tw = 1 - abs(dayF * 2 - 1)                    // twilight peaks at dawn/dusk
    let zenith = mix3((0.02, 0.03, 0.10), (0.40, 0.60, 0.95), dayF)
    let horizon = mix3(mix3((0.05, 0.07, 0.16), (0.72, 0.82, 0.96), dayF),
                       (0.85, 0.52, 0.32), tw * 0.55)
    let sky = zenith

    // procedural cloud layer: sky rays that cross y = cloudY sample FBM noise.
    let clouds = FBM(1337, 4, 0.006)
    let cloudY = 196.0
    let cloudLit = mix3((0.60, 0.60, 0.66), (1.0, 1.0, 1.0), dayF)          // grey at night, white by day
    let cloudCol = mix3(cloudLit, (0.97, 0.72, 0.62), tw * 0.5)             // pinkish at dawn/dusk

    for py in 0..<H {
        let sv = (1 - 2 * (Double(py) + 0.5) / Double(H)) * tanHalf
        for px in 0..<W {
            let su = (2 * (Double(px) + 0.5) / Double(W) - 1) * tanHalf * aspect
            var dx = fx + rx * su + ux * sv
            var dy = fy + ry * su + uy * sv
            var dz = fz + rz * su + uz * sv
            let n = 1 / (dx * dx + dy * dy + dz * dz).squareRoot()
            dx *= n; dy *= n; dz *= n

            var s = mix3(horizon, sky, max(0, min(1, dy * 1.4)))
            // clouds: where an up-going ray crosses the cloud plane, blend puffs in
            if dy > 0.04 {
                let t = (cloudY - cam.y) / dy
                if t > 0 {
                    let dens = (clouds.sample2(cam.x + dx * t, cam.z + dz * t) + 1) * 0.5
                    let cov = smoothstepD(max(0, min(1, (dens - 0.5) / 0.2))) * min(1, dy * 3)
                    if cov > 0 { s = mix3(s, cloudCol, cov * 0.9) }
                }
            }
            // castRay returns premultiplied colour + remaining transmittance;
            // whatever light gets through composites over the sky for this ray.
            let c = castRay(world, atlas, cam.x, cam.y, cam.z, dx, dy, dz, maxDist, horizon)
            f.set(px, py, c.0 + c.3 * s.0, c.1 + c.3 * s.1, c.2 + c.3 * s.2)
        }
    }
}

/// Returns premultiplied colour + remaining transmittance (trans). trans == 1
/// means the ray saw only sky; an opaque hit drives trans to 0; translucent
/// blocks (water/glass/ice) accumulate colour and reduce trans as the ray passes
/// through; cutout blocks (leaves/glass) are alpha-tested per texel.
private func castRay(_ world: World, _ atlas: Atlas, _ ox: Double, _ oy: Double, _ oz: Double,
                     _ dx: Double, _ dy: Double, _ dz: Double, _ maxDist: Int,
                     _ horizon: (Double, Double, Double)) -> (Double, Double, Double, Double) {
    var ix = Int(ox.rounded(.down)), iy = Int(oy.rounded(.down)), iz = Int(oz.rounded(.down))
    let stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1
    let tDX = dx == 0 ? Double.infinity : abs(1 / dx)
    let tDY = dy == 0 ? Double.infinity : abs(1 / dy)
    let tDZ = dz == 0 ? Double.infinity : abs(1 / dz)
    func firstB(_ o: Double, _ i: Int, _ step: Int, _ td: Double) -> Double {
        if td == .infinity { return .infinity }
        return (step > 0 ? Double(i + 1) - o : o - Double(i)) * td
    }
    var tMaxX = firstB(ox, ix, stepX, tDX)
    var tMaxY = firstB(oy, iy, stepY, tDY)
    var tMaxZ = firstB(oz, iz, stepZ, tDZ)

    var axis = 1
    var travelled = 0.0
    var accR = 0.0, accG = 0.0, accB = 0.0, trans = 1.0

    for _ in 0..<(maxDist * 3) {
        let packed = world.getBlock(ix, iy, iz)
        let id = packed >> 4
        if id > 0 && id < blockDefs.count {
            let def = blockDefs[id]
            let hx = ox + dx * travelled, hy = oy + dy * travelled, hz = oz + dz * travelled
            let face: Int, u: Double, v: Double, faceShade: Double
            switch axis {
            case 1: face = stepY < 0 ? 1 : 0; u = frac(hx); v = frac(hz); faceShade = stepY < 0 ? 1.0 : 0.5
            case 2: face = stepZ < 0 ? 3 : 2; u = frac(hx); v = 1 - frac(hy); faceShade = 0.80
            default: face = stepX < 0 ? 5 : 4; u = frac(hz); v = 1 - frac(hy); faceShade = 0.62
            }
            // shaded, tinted, fog-blended texel for this face
            func texel() -> (Double, Double, Double, Double) {
                let tile = atlas.tile(forCell: packed, face: face)
                var (r, g, b, a) = atlas.sample(tile, u, v)
                let tint = blockTint(def.name, face)
                r *= tint.0; g *= tint.1; b *= tint.2
                // real engine light at the air neighbour × directional face shade
                let off = FACE_OFF[face]
                let light = world.lightAt(ix + off.0, iy + off.1, iz + off.2) / 15.0
                let lit = max(0.05, light) * faceShade
                let fog = max(0, 1 - travelled / Double(maxDist)) * 0.85 + 0.15
                let c = mix3(horizon, (r * lit, g * lit, b * lit), fog)
                return (c.0, c.1, c.2, a)
            }

            if def.translucent {                        // water, ice, stained glass…
                let (r, g, b, ta) = texel()
                let a = translucentAlpha(def.name, ta)
                accR += trans * a * r; accG += trans * a * g; accB += trans * a * b
                trans *= (1 - a)
                if trans < 0.05 { break }
            } else if def.fullCube && def.opaque && !def.transparentRender {   // solid
                let (r, g, b, _) = texel()
                accR += trans * r; accG += trans * g; accB += trans * b
                trans = 0; break
            } else if def.fullCube && def.transparentRender {                  // cutout
                let (r, g, b, a) = texel()
                if a >= 0.5 {
                    accR += trans * r; accG += trans * g; accB += trans * b
                    trans = 0; break
                }
                // transparent texel — see through the holes
            }
            // non-full-cube plants/cross shapes: ray passes through (skipped)
        }
        if tMaxX < tMaxY {
            if tMaxX < tMaxZ { ix += stepX; travelled = tMaxX; tMaxX += tDX; axis = 0 }
            else { iz += stepZ; travelled = tMaxZ; tMaxZ += tDZ; axis = 2 }
        } else {
            if tMaxY < tMaxZ { iy += stepY; travelled = tMaxY; tMaxY += tDY; axis = 1 }
            else { iz += stepZ; travelled = tMaxZ; tMaxZ += tDZ; axis = 2 }
        }
    }
    return (accR, accG, accB, trans)
}

/// Per-class opacity for translucent blocks (the substrate tiles are near-opaque).
private func translucentAlpha(_ name: String, _ texelAlpha: Double) -> Double {
    if name == "water" { return 0.62 }
    if name.contains("ice") { return 0.55 }
    if name.contains("glass") { return 0.45 }
    return max(0.4, min(0.85, texelAlpha))
}

/// Biome-ish tint for the tiles the engine tints at runtime (grass tops, foliage).
/// The substrate paints these grayscale to be coloured here.
private func blockTint(_ name: String, _ face: Int) -> (Double, Double, Double) {
    if name == "grass_block" { return face == 1 ? (0.45, 0.72, 0.35) : (1, 1, 1) }
    if name.contains("leaves") || name.contains("vine") || name.hasPrefix("grass")
        || name == "fern" || name.contains("moss") { return (0.36, 0.62, 0.30) }
    if name == "water" { return (0.25, 0.5, 0.92) }
    return (1, 1, 1)
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
