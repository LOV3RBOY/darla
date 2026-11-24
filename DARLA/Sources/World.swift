import Foundation
import RealityKit
import Metal
import Compression
import simd

/// One flower in the world: its splats live in a contiguous range so we can animate them.
struct FlowerInfo: Codable {
    let id: String
    let center: [Float]
    let radius: Float
    let start: Int
    let count: Int
}

struct WorldManifest: Codable {
    let count: Int
    let rawSize: Int
    let flowerCount: Int
    let flowers: [FlowerInfo]
    let tiers: [Int]
}

/// Detail level. Splats are stored most-important first, so lower tiers only drop the faintest distant ones.
enum Quality: Int, CaseIterable {
    case smooth, high, ultra
    static var current: Quality {
        get { Quality(rawValue: (UserDefaults.standard.object(forKey: "darla.quality") as? Int) ?? 2) ?? .ultra }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "darla.quality") }
    }
    var label: String { ["Smooth", "High", "Ultra"][rawValue] }
}

/// Animated flower layer: pos3 scale3 rot4(w,x,y,z) opacity1 sh3 = 14 floats, padded to 16.
let kFloatsPerSplat = 16
let kStride = kFloatsPerSplat * MemoryLayout<Float>.size
/// Static forest layer (never rewritten): float3 position + half precision for the rest = 36 bytes.
let kStaticStride = 36

/// Rest-state data for one flower, kept on the CPU so the bloom can be animated every frame.
final class FlowerSplats {
    let info: FlowerInfo
    let center: SIMD3<Float>
    var rest: [Float]          // kFloatsPerSplat floats per splat, untouched copy
    var delay: [Float]         // per-splat bloom delay (inner petals first)
    init(info: FlowerInfo, rest: [Float]) {
        self.info = info
        self.center = SIMD3(info.center[0], info.center[1], info.center[2])
        self.rest = rest
        var d = [Float](repeating: 0, count: info.count)
        var maxR: Float = 0.001
        for i in 0..<info.count {
            let b = i * kFloatsPerSplat
            let p = SIMD3(rest[b], rest[b + 1], rest[b + 2])
            let r = simd_length(p - center)
            d[i] = r; maxR = max(maxR, r)
        }
        for i in 0..<info.count { d[i] = 0.55 * (d[i] / maxR) + 0.15 * Float((i &* 2654435761) % 1000) / 1000 }
        self.delay = d
    }
}

enum WorldError: Error { case missing, decode, tooMany }

/// Loads world.bin (raw-deflate SPZ v2 layout) into a RealityKit LowLevelBuffer.
final class WorldLoader: @unchecked Sendable {
    let manifest: WorldManifest
    var buffer: LowLevelBuffer!          // flowers (animated)
    var staticBuffer: LowLevelBuffer!    // forest + arcade (static)
    var flowerCount = 0
    var staticCount = 0
    var flowers: [FlowerSplats] = []

    init() throws {
        guard let mURL = Bundle.main.url(forResource: "world", withExtension: "json"),
              let bURL = Bundle.main.url(forResource: "world", withExtension: "bin") else { throw WorldError.missing }
        manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: mURL))
        let packed = try Data(contentsOf: bURL)
        let raw = try WorldLoader.inflate(packed, size: manifest.rawSize)
        try decode(raw)
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw WorldError.decode }
        return out
    }

    private func decode(_ raw: Data) throws {
        try raw.withUnsafeBytes { (rb: UnsafeRawBufferPointer) in
            let base = rb.bindMemory(to: UInt8.self).baseAddress!
            let n = Int(rb.load(fromByteOffset: 8, as: UInt32.self))
            let frac = Float(1 << Int(base[13]))
            let nf = manifest.flowerCount
            let tierCount = manifest.tiers.indices.contains(Quality.current.rawValue) ? manifest.tiers[Quality.current.rawValue] : n
            flowerCount = nf; staticCount = max(nf, min(n, tierCount))   // one layer: flowers + world, sorted together
            let posO = 16, alO = posO + n * 9, colO = alO + n, scO = colO + 3 * n, roO = scO + 3 * n

            @inline(__always) func splat(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>, Float, SIMD3<Float>) {
                var p = SIMD3<Float>(), s = SIMD3<Float>(), c = SIMD3<Float>()
                for a in 0..<3 {
                    let q = base + posO + i * 9 + a * 3
                    var v = Int32(q[0]) | (Int32(q[1]) << 8) | (Int32(q[2]) << 16)
                    if v & 0x800000 != 0 { v |= Int32(bitPattern: 0xFF000000) }
                    p[a] = Float(v) / frac
                    s[a] = exp(Float(base[scO + i * 3 + a]) / 16 - 10)
                    c[a] = (Float(base[colO + i * 3 + a]) / 255 - 0.5) / 0.15
                }
                let qx = Float(base[roO + i * 3]) / 127.5 - 1, qy = Float(base[roO + i * 3 + 1]) / 127.5 - 1, qz = Float(base[roO + i * 3 + 2]) / 127.5 - 1
                let qw = sqrt(max(0, 1 - qx * qx - qy * qy - qz * qz))
                return (p, s, SIMD4(qw, qx, qy, qz), Float(base[alO + i]) / 255, c)
            }

            // animated flower layer (float)
            buffer = try LowLevelBuffer(descriptor: .init(capacity: max(16, (nf * kStride + 15) & ~0xF), sizeMultiple: 16))
            buffer.withUnsafeMutableBytes { dst in
                let f = dst.bindMemory(to: Float.self).baseAddress!
                for i in 0..<nf {
                    let (p, s, r, a, c) = splat(i), o = f + i * kFloatsPerSplat
                    o[0] = p.x; o[1] = p.y; o[2] = p.z; o[3] = s.x; o[4] = s.y; o[5] = s.z
                    o[6] = r.x; o[7] = r.y; o[8] = r.z; o[9] = r.w; o[10] = a
                    o[11] = c.x; o[12] = c.y; o[13] = c.z; o[14] = 0; o[15] = 0
                }
                for info in manifest.flowers {
                    let start = f + info.start * kFloatsPerSplat
                    flowers.append(FlowerSplats(info: info, rest: Array(UnsafeBufferPointer(start: start, count: info.count * kFloatsPerSplat))))
                }
            }

            // static forest layer (float3 position, half everything else)
            let sc = staticCount
            staticBuffer = try LowLevelBuffer(descriptor: .init(capacity: (sc * kStaticStride + 15) & ~0xF, sizeMultiple: 16))
            staticBuffer.withUnsafeMutableBytes { dst in
                let b = dst.baseAddress!
                for j in 0..<sc {
                    let (p, s, r, a, c) = splat(j)
                    let o = b + j * kStaticStride
                    o.storeBytes(of: p.x, toByteOffset: 0, as: Float.self)
                    o.storeBytes(of: p.y, toByteOffset: 4, as: Float.self)
                    o.storeBytes(of: p.z, toByteOffset: 8, as: Float.self)
                    let h = o + 12
                    h.storeBytes(of: Float16(s.x), toByteOffset: 0, as: Float16.self)
                    h.storeBytes(of: Float16(s.y), toByteOffset: 2, as: Float16.self)
                    h.storeBytes(of: Float16(s.z), toByteOffset: 4, as: Float16.self)
                    h.storeBytes(of: Float16(r.x), toByteOffset: 6, as: Float16.self)
                    h.storeBytes(of: Float16(r.y), toByteOffset: 8, as: Float16.self)
                    h.storeBytes(of: Float16(r.z), toByteOffset: 10, as: Float16.self)
                    h.storeBytes(of: Float16(r.w), toByteOffset: 12, as: Float16.self)
                    h.storeBytes(of: Float16(a), toByteOffset: 14, as: Float16.self)
                    h.storeBytes(of: Float16(c.x), toByteOffset: 16, as: Float16.self)
                    h.storeBytes(of: Float16(c.y), toByteOffset: 18, as: Float16.self)
                    h.storeBytes(of: Float16(c.z), toByteOffset: 20, as: Float16.self)
                    h.storeBytes(of: Float16(0), toByteOffset: 22, as: Float16.self)
                }
            }
        }
    }

    @MainActor private func entity(count: Int, buffer: LowLevelBuffer, stride: Int, half: Bool) throws -> Entity {
        func d(_ fmt: MTLAttributeFormat, _ off: Int) -> GaussianSplatResource.BufferDescriptor {
            .init(buffer: buffer, format: fmt, stride: stride, offset: off)
        }
        let br: GaussianSplatResource.BufferResource
        if half {
            br = try GaussianSplatResource.BufferResource(
                count: count, position: d(.float3, 0), scale: d(.half3, 12), rotation: d(.half4, 18),
                opacity: d(.half, 26), sphericalHarmonics: (d(.half3, 28), .zero))
        } else {
            let F = MemoryLayout<Float>.size
            br = try GaussianSplatResource.BufferResource(
                count: count, position: d(.float3, 0), scale: d(.float3, 3 * F), rotation: d(.float4, 6 * F),
                opacity: d(.float, 10 * F), sphericalHarmonics: (d(.float3, 11 * F), .zero))
        }
        let res = GaussianSplatResource(br)
        res.scaleActivation = GaussianSplatResource.ActivationFunction.identity
        res.opacityActivation = GaussianSplatResource.ActivationFunction.identity
        res.sortingMode = GaussianSplatResource.SortingMode.distance
        let e = Entity()
        e.components.set(GaussianSplatComponent(res))
        return e
    }

    /// Two splat entities: the static forest and the animated flowers.
    @MainActor func makeEntities() throws -> (world: Entity, flowers: Entity) {
        var count = staticCount
        var world: Entity?
        while world == nil {
            do { world = try entity(count: count, buffer: staticBuffer, stride: kStaticStride, half: true) }
            catch {
                count = Int(Double(count) * 0.8)
                if count < 200_000 { throw WorldError.tooMany }
            }
        }
        // Flowers live inside the single world layer so every splat depth-sorts together (no seams, no halos).
        let fl = Entity()
        world!.name = "world"; fl.name = "flowers"
        return (world!, fl)
    }
}
