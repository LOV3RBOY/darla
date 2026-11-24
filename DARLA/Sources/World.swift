import Foundation
import RealityKit
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
    let flowers: [FlowerInfo]
}

/// Interleaved splat layout handed to RealityKit: pos3 scale3 rot4(w,x,y,z) opacity1 sh3 = 14 floats, padded to 16.
let kFloatsPerSplat = 16
let kStride = kFloatsPerSplat * MemoryLayout<Float>.size

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
    var buffer: LowLevelBuffer!
    var splatCount = 0
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
            splatCount = n
            let posO = 16, alO = posO + n * 9, colO = alO + n, scO = colO + 3 * n, roO = scO + 3 * n
            let cap = ((n * kStride + 15) & ~0xF)
            buffer = try LowLevelBuffer(descriptor: .init(capacity: cap, sizeMultiple: 16))
            buffer.withUnsafeMutableBytes { dst in
                let f = dst.bindMemory(to: Float.self).baseAddress!
                for i in 0..<n {
                    let o = f + i * kFloatsPerSplat
                    for a in 0..<3 {
                        let p = base + posO + i * 9 + a * 3
                        var v = Int32(p[0]) | (Int32(p[1]) << 8) | (Int32(p[2]) << 16)
                        if v & 0x800000 != 0 { v |= Int32(bitPattern: 0xFF000000) }
                        o[a] = Float(v) / frac
                        o[3 + a] = exp(Float(base[scO + i * 3 + a]) / 16 - 10)
                        o[11 + a] = (Float(base[colO + i * 3 + a]) / 255 - 0.5) / 0.15
                    }
                    let qx = Float(base[roO + i * 3]) / 127.5 - 1
                    let qy = Float(base[roO + i * 3 + 1]) / 127.5 - 1
                    let qz = Float(base[roO + i * 3 + 2]) / 127.5 - 1
                    let qw = sqrt(max(0, 1 - qx * qx - qy * qy - qz * qz))
                    o[6] = qw; o[7] = qx; o[8] = qy; o[9] = qz
                    o[10] = Float(base[alO + i]) / 255
                    o[14] = 0; o[15] = 0
                }
                for info in manifest.flowers {
                    let start = f + info.start * kFloatsPerSplat
                    let rest = Array(UnsafeBufferPointer(start: start, count: info.count * kFloatsPerSplat))
                    flowers.append(FlowerSplats(info: info, rest: rest))
                }
            }
        }
    }

    /// Builds the splat entity. If RealityKit refuses the full count, retries with fewer background splats.
    func makeEntity() throws -> Entity {
        var count = splatCount
        let floor = manifest.flowers.map { $0.start + $0.count }.max() ?? 0
        while true {
            do {
                func d(_ fmt: MTLAttributeFormat, _ off: Int) -> GaussianSplatResource.BufferDescriptor {
                    .init(buffer: buffer, format: fmt, stride: kStride, offset: off * MemoryLayout<Float>.size)
                }
                let br = try GaussianSplatResource.BufferResource(
                    count: count, position: d(.float3, 0), scale: d(.float3, 3), rotation: d(.float4, 6),
                    opacity: d(.float, 10), sphericalHarmonics: (d(.float3, 11), .zero))
                let res = GaussianSplatResource(br)
                res.scaleActivation = .identity
                res.opacityActivation = .identity
                res.sortingMode = .distance
                let e = Entity()
                e.name = "world"
                e.components.set(GaussianSplatComponent(res))
                return e
            } catch {
                let next = Int(Double(count) * 0.8)
                if next <= floor { throw WorldError.tooMany }
                count = next
            }
        }
    }
}
