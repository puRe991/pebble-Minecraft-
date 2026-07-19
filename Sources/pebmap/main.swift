// pebmap — a headless world-map renderer for Pebble.
//
// It drives the real PebbleCore worldgen (the exact same deterministic engine
// the game uses) and writes a top-down shaded-relief map of the overworld to a
// BMP file. No window, no Metal, no Apple frameworks — so it runs anywhere the
// engine builds, including Windows and Linux. This is the first thing you can
// *see* Pebble produce off-Apple: a genuine Pebble world from a seed.
//
//   swift run -c release pebmap [--seed N] [--chunks N] [--out FILE.bmp]
//
// Same seed → byte-identical map on every platform (the determinism contract).

import Foundation
import PebbleCore

// ---- args --------------------------------------------------------------------
var seed: UInt32 = 4242
var chunks = 48            // grid is chunks×chunks (×16 px each)
var outPath = ""

var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    switch argv[i] {
    case "--seed":   if i + 1 < argv.count { seed = UInt32(truncatingIfNeeded: Int(argv[i + 1]) ?? 4242); i += 1 }
    case "--chunks": if i + 1 < argv.count { chunks = max(4, min(160, Int(argv[i + 1]) ?? 48)); i += 1 }
    case "--out":    if i + 1 < argv.count { outPath = argv[i + 1]; i += 1 }
    case "-h", "--help":
        print("usage: pebmap [--seed N] [--chunks N] [--out FILE.bmp]")
        exit(0)
    default: break
    }
    i += 1
}
if outPath.isEmpty { outPath = "pebble-map-\(seed).bmp" }

// ---- generate ----------------------------------------------------------------
registerAllBlocks()
registerAllBiomes()

let gen = OverworldGen(seed)
let W = chunks * 16
let cxMin = -chunks / 2
let czMin = -chunks / 2

var height = [Float](repeating: 0, count: W * W)   // terrain surface y per column
var water  = [Bool](repeating: false, count: W * W)

print("pebmap: generating \(chunks)×\(chunks) chunks (\(W)×\(W) px) from seed \(seed)…")
let t0 = nowSeconds()
for ccz in 0..<chunks {
    for ccx in 0..<chunks {
        let cx = cxMin + ccx
        let cz = czMin + ccz
        var blocks = [UInt16](repeating: 0, count: 16 * 16 * WORLD_H)
        var biomes = [UInt8](repeating: 0, count: 4 * 4 * ((WORLD_H + 3) / 4))
        let res = gen.fillTerrain(cx, cz, &blocks, &biomes)
        for lz in 0..<16 {
            for lx in 0..<16 {
                let h = Int(res.heights[lz * 16 + lx])
                let px = ccx * 16 + lx
                let pz = ccz * 16 + lz
                let gi = pz * W + px
                height[gi] = Float(h)
                water[gi] = h < SEA
            }
        }
    }
}
print(String(format: "pebmap: worldgen done in %.2fs", nowSeconds() - t0))

// ---- shade + colorize --------------------------------------------------------
@inline(__always) func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }
@inline(__always) func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

// land elevation ramp (beach → grass → forest → rock → snow)
func landColor(_ h: Double) -> (Double, Double, Double) {
    let beach  = (0.83, 0.77, 0.55)
    let grass  = (0.40, 0.58, 0.28)
    let forest = (0.24, 0.42, 0.20)
    let rock   = (0.44, 0.41, 0.38)
    let snow   = (0.95, 0.96, 0.98)
    switch h {
    case ..<66:   return mix(beach, grass, clamp01((h - 63) / 3))
    case ..<96:   return mix(grass, forest, clamp01((h - 66) / 30))
    case ..<150:  return mix(forest, rock, clamp01((h - 96) / 54))
    case ..<205:  return mix(rock, snow, clamp01((h - 150) / 55))
    default:      return snow
    }
}

// water depth ramp (shallow → deep)
func waterColor(_ h: Double) -> (Double, Double, Double) {
    let shallow = (0.36, 0.60, 0.76)
    let deep    = (0.04, 0.10, 0.32)
    return mix(shallow, deep, clamp01((Double(SEA) - h) / 40))
}

var pixels = [UInt8](repeating: 0, count: W * W * 3)   // RGB, top row first
for z in 0..<W {
    for x in 0..<W {
        let gi = z * W + x
        let h = Double(height[gi])

        var c: (Double, Double, Double)
        if water[gi] {
            c = waterColor(h)
        } else {
            // hillshade from a NW light, using terrain slope
            let hl = Double(height[z * W + max(0, x - 1)])
            let hr = Double(height[z * W + min(W - 1, x + 1)])
            let hu = Double(height[max(0, z - 1) * W + x])
            let hd = Double(height[min(W - 1, z + 1) * W + x])
            let dx = hr - hl
            let dz = hd - hu
            // normal (-dx, 2, -dz) · light (-1, 1.6, -1), both normalized
            let nlen = (dx * dx + 4 + dz * dz).squareRoot()
            let llen = (1 + 1.6 * 1.6 + 1).squareRoot()
            let lambert = (dx + 2 * 1.6 + dz) / (nlen * llen)
            let shade = 0.55 + 0.75 * clamp01(lambert)   // 0.55…1.3
            c = landColor(h)
            c = (clamp01(c.0 * shade), clamp01(c.1 * shade), clamp01(c.2 * shade))
        }
        let o = gi * 3
        pixels[o]     = UInt8(clamp01(c.0) * 255 + 0.5)
        pixels[o + 1] = UInt8(clamp01(c.1) * 255 + 0.5)
        pixels[o + 2] = UInt8(clamp01(c.2) * 255 + 0.5)
    }
}

// ---- write a 24-bit BMP (no compression → no zlib dependency) -----------------
func writeBMP(_ path: String, _ rgb: [UInt8], _ w: Int, _ h: Int) {
    let rowSize = ((w * 3 + 3) / 4) * 4
    let imgSize = rowSize * h
    let fileSize = 54 + imgSize
    var d = Data(capacity: fileSize)
    func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    // BITMAPFILEHEADER
    d.append(0x42); d.append(0x4D)          // "BM"
    u32(fileSize); u16(0); u16(0); u32(54)
    // BITMAPINFOHEADER
    u32(40); u32(w); u32(h); u16(1); u16(24); u32(0); u32(imgSize); u32(2835); u32(2835); u32(0); u32(0)
    // pixel rows: bottom-up, BGR, padded
    let pad = rowSize - w * 3
    for row in stride(from: h - 1, through: 0, by: -1) {
        for x in 0..<w {
            let o = (row * w + x) * 3
            d.append(rgb[o + 2]); d.append(rgb[o + 1]); d.append(rgb[o])   // B G R
        }
        for _ in 0..<pad { d.append(0) }
    }
    try? d.write(to: URL(fileURLWithPath: path))
}

writeBMP(outPath, pixels, W, W)
print("pebmap: wrote \(outPath) (\(W)×\(W))")
