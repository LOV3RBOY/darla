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

    func update(dt: Float) {
        time += dt
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: Float.self).baseAddress!
            for f in flowers {
                switch f.phase {
                case .dormant:
                    if f.dirty || Int(time * 30) % 2 == 0 { write(f, base: base, open: 0, glow: 0) }
                case .blooming:
                    f.t += dt
                    write(f, base: base, open: f.t / Self.bloomDuration, glow: 1)
                    if f.t >= Self.bloomDuration + 0.8 { f.phase = .alive }
                case .alive:
                    write(f, base: base, open: 1.2, glow: 0)
                }
                f.dirty = false
            }
        }
    }

    /// open: 0 = bud, 1 = fully open (values above 1 = settled + breathing).
    private func write(_ f: Flower, base: UnsafeMutablePointer<Float>, open: Float, glow: Float) {
        let s = f.splats, n = s.info.count, c = s.center
        let dst = base + s.info.start * kFloatsPerSplat
        let breathe = sin(time * 1.3 + c.x * 7) * 0.012
        let pulse = 0.5 + 0.5 * sin(time * 2.2 + c.y * 5)
        s.rest.withUnsafeBufferPointer { restBuf in
            let rest = restBuf.baseAddress!
            for i in 0..<n {
                let r = rest + i * kFloatsPerSplat, o = dst + i * kFloatsPerSplat
                // per-splat progress: inner petals lead, outer ones follow
                let local: Float
                if open >= 1.2 { local = 1 } else {
                    let d = s.delay[i]
                    local = min(1, max(0, (open * 1.7 - d) / 0.9))
                }
                let e = open >= 1.2 ? 1 : (local <= 0 ? 0 : (local >= 1 ? 1 : easeOutBack(local)))
                var rel = SIMD3(r[0] - c.x, r[1] - c.y, r[2] - c.z)
                // bud: pulled toward the center and twisted; opening unwinds the twist
                let squeeze = 0.16 + 0.84 * e
                let ang = (1 - e) * 1.25 * (0.6 + s.delay[i])
                let ca = cos(ang), sa = sin(ang)
                rel = SIMD3(rel.x * ca - rel.z * sa, rel.y * (0.55 + 0.45 * e), rel.x * sa + rel.z * ca) * squeeze
                if open >= 1.2 { rel *= 1 + breathe * (0.5 + s.delay[i]) }
                o[0] = c.x + rel.x; o[1] = c.y + rel.y; o[2] = c.z + rel.z
                let sc = 0.45 + 0.55 * e
                o[3] = r[3] * sc; o[4] = r[4] * sc; o[5] = r[5] * sc
                o[10] = r[10] * (0.7 + 0.3 * e)
                // color: dormant is a cool dim ghost with a soft pulse, blooming flares warm light mid-unfurl
                let flare = glow * sin(Float.pi * min(1, local)) * 0.9
                let dim = open == 0 ? (0.32 + 0.1 * pulse) : (0.32 + 0.68 * e)
                for k in 0..<3 {
                    let col = 0.5 + 0.282095 * r[11 + k]
                    let tint: Float = open == 0 ? (k == 0 ? 0.95 : (k == 1 ? 1.0 : 1.25)) : 1
                    let lit = col * dim * tint + flare * (k == 2 ? 0.55 : 0.75)
                    o[11 + k] = (lit - 0.5) / 0.282095
                }
            }
        }
    }
}
