import Foundation
import RealityKit
import simd

/// Drives the life of each flower inside the splat world:
/// dormant (folded into a dim, glowing bud) -> blooming (petals unfurl outward in a spiral, light flares)
/// -> alive (gentle breathing sway forever).
final class BloomController {
    enum Phase { case dormant, blooming, alive }

    final class Flower {
        let splats: FlowerSplats
        var phase: Phase = .dormant
        var t: Float = 0
        var dirty = true
        init(_ s: FlowerSplats) { splats = s }
        var center: SIMD3<Float> { splats.center }
        var id: String { splats.info.id }
    }

    let flowers: [Flower]
    let buffer: LowLevelBuffer
    static let bloomDuration: Float = 3.4
    private var time: Float = 0

    init(world: WorldLoader) {
        flowers = world.flowers.map(Flower.init)
        buffer = world.buffer
    }

    func bloom(_ f: Flower) {
        guard f.phase == .dormant else { return }
        f.phase = .blooming; f.t = 0
    }

    /// Ease with a small overshoot so petals settle like they have weight.
    @inline(__always) private func easeOutBack(_ x: Float) -> Float {
        let c1: Float = 1.4, c3 = c1 + 1
        let k = x - 1
        return 1 + c3 * k * k * k + c1 * k * k
    }

    private var idleClock: Float = 0

    /// Writes only what changed: every frame while a flower is opening, ~12 Hz for idle pulse/breathing.
    func update(dt: Float) {
        time += dt
        idleClock += dt
        // only touch the GPU buffer while a flower is actually changing
        // The captured flowers are never altered: bloom is pure light + particles, so the world stays pristine.
        for f in flowers where f.phase == .blooming {
            f.t += dt
            if f.t >= Self.bloomDuration + 0.8 { f.phase = .alive }
        }
    }

    /// open: 0 = dormant, 0..1 = blooming, >= 1.2 = alive.
    /// Geometry is never collapsed: the real flower always keeps its exact shape and detail.
    /// Dormant = softly shaded and cool; blooming = a gentle swell with a warm wave of light rolling outward from the heart.
    private func write(_ f: Flower, base: UnsafeMutablePointer<Float>, open: Float, glow: Float) {
        let s = f.splats, n = s.info.count, c = s.center
        let dst = base + s.info.start * kFloatsPerSplat
        s.rest.withUnsafeBufferPointer { restBuf in
            let rest = restBuf.baseAddress!
            for i in 0..<n {
                let r = rest + i * kFloatsPerSplat, o = dst + i * kFloatsPerSplat
                let d = s.delay[i]                                  // 0 at the heart .. ~0.7 at the tips
                var e: Float = 1, wave: Float = 0
                if open < 1.2 {
                    let local = min(1, max(0, (open * 1.6 - d) / 0.7))
                    e = local <= 0 ? 0 : (local >= 1 ? 1 : easeOutBack(local))
                    wave = glow * sin(Float.pi * local)
                }
                // a small, elastic swell outward as the light passes (max ~5%), then settle exactly at rest
                let swell = 1 + 0.05 * wave
                o[0] = c.x + (r[0] - c.x) * swell
                o[1] = c.y + (r[1] - c.y) * swell
                o[2] = c.z + (r[2] - c.z) * swell
                o[3] = r[3]; o[4] = r[4]; o[5] = r[5]
                o[10] = r[10]
                let dim: Float = open == 0 ? 0.62 : (0.62 + 0.38 * e)
                for k in 0..<3 {
                    let col = 0.5 + 0.282095 * r[11 + k]
                    let cool: Float = open == 0 ? (k == 0 ? 0.94 : (k == 1 ? 0.98 : 1.08)) : 1
                    let lit = col * dim * cool + wave * (k == 2 ? 0.28 : 0.42)
                    o[11 + k] = (lit - 0.5) / 0.282095
                }
            }
        }
    }
}
