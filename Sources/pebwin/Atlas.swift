// Atlas — the engine's code-generated texture atlas, made available to the
// front-end renderers. `buildAtlas()` (PebbleCore, no Metal) paints every tile
// as 16×16 RGBA; this wraps that with a per-block face-tile lookup (via the
// engine's TILE_TABLE) and a sampler, so both the CPU raycaster and the GPU
// backend draw the real block textures rather than flat colours.

import Foundation
import PebbleCore

final class Atlas {
    let count: Int
    let tileBytes = TILE * TILE * 4
    let pixels: [[UInt8]]        // pixels[tileIndex] = TILE*TILE*4 RGBA

    init() {
        let built = buildAtlas()
        count = built.count
        pixels = built.pixels
    }

    /// One contiguous RGBA blob of all tiles, tile 0 first — for GPU array upload.
    func packed() -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(count * tileBytes)
        for t in pixels { out.append(contentsOf: t) }
        return out
    }

    /// Tile index for a world block's face (dir: 0=-y 1=+y 2=-z 3=+z 4=-x 5=+x).
    @inline(__always) func tile(forCell cell: Int, face: Int) -> Int {
        let i = (cell << 3) | face
        guard i >= 0 && i < TILE_TABLE.count else { return 0 }
        return Int(TILE_TABLE[i])
    }

    /// Nearest-sample a tile at tile-local (u,v) ∈ [0,1). Returns RGBA in 0…1.
    @inline(__always) func sample(_ tile: Int, _ u: Double, _ v: Double) -> (Double, Double, Double, Double) {
        guard tile >= 0 && tile < count else { return (1, 0, 1, 1) }
        let px = pixels[tile]
        let tx = min(TILE - 1, max(0, Int(u * Double(TILE))))
        let ty = min(TILE - 1, max(0, Int(v * Double(TILE))))
        let o = (ty * TILE + tx) * 4
        return (Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255, Double(px[o + 3]) / 255)
    }
}
