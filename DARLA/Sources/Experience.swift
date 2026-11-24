import SwiftUI
import RealityKit
import UIKit
import simd

struct Place: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let size: Float
    let pos: SIMD3<Float>
    let look: SIMD3<Float>
}

/// The whole living scene: camera, splat world, blooms, particles, the arcade.
@MainActor @Observable
final class Experience {
    // UI state
    var loading = true
    var loadError: String?
    var started = false
    var bloomed: [Bool] = []
    var toastTitle = ""
    var toastKicker = ""
    var toastLine = ""
    var toastVisible = false
    var nearScreen = false
    var playing = false
    var awake = false
    var size: Float = 0.2
    var sizeLabel = ""

    // input
    var move = SIMD2<Float>(0, 0)   // x = strafe, y = forward
    var lift: Float = 0

    let places: [Place] = [
        .init(name: "The forest floor", detail: "Ladybug-sized among the roots", size: 0.06, pos: [3.05, 0.12, 3.45], look: [2.1, 1.5, 4.5]),
        .init(name: "The chrome peony", detail: "Petals poured from mercury", size: 0.06, pos: [2.74, 0.62, 3.75], look: [2.37, 0.6, 4.15]),
        .init(name: "The glowing screen", detail: "Where the arcade dreams", size: 0.2, pos: [2.21, 2.11, 3.81], look: [1.885, 1.86, 4.59]),
        .init(name: "The dew lily", detail: "Resting on the controls", size: 0.08, pos: [2.34, 1.5, 3.94], look: [2.0, 1.45, 4.3]),
        .init(name: "Under the orchids", detail: "Petals the size of sails", size: 0.1, pos: [2.9, 2.3, 4.35], look: [2.45, 3.0, 5.0]),
        .init(name: "Human height", detail: "The whole shrine at once", size: 1, pos: [4.18, 2.3, 2.26], look: [2.0, 1.6, 4.6]),
    ]
    let flowerNames = ["peony": ("The chrome peony", "Its mirrored petals catch the sun."),
                       "lily": ("The dew lily", "Every droplet lights up."),
                       "callas": ("The white callas", "They open like trumpets."),
                       "glass": ("The glass blossoms", "Light pours straight through them."),
                       "orchids": ("The orchids", "They unfurl overhead.")]

    // scene
    @ObservationIgnored var updateSub: EventSubscription?
    let root = Entity()
    let camera = PerspectiveCamera()
    @ObservationIgnored private var world: WorldLoader?
    @ObservationIgnored private var bloom: BloomController?
    @ObservationIgnored private var beacons: [Entity] = []
    @ObservationIgnored private var bursts: [Entity] = []
    @ObservationIgnored private var screen: ModelEntity?
    @ObservationIgnored private var screenTexture: TextureResource?
    let arcade = PetalRun()
    @ObservationIgnored private var camPos = SIMD3<Float>(4.18, 2.3, 2.26)
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var pitch: Float = 0
    @ObservationIgnored private var flight: (from: SIMD3<Float>, to: SIMD3<Float>, fq: simd_quatf, tq: simd_quatf, t: Float, dur: Float)?
    @ObservationIgnored private var targetSize: Float = 0.2
    @ObservationIgnored private var screenClock: Float = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    let audio = AudioDirector()
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    static let screenCenter = SIMD3<Float>(1.885, 1.86, 4.59)
    static let screenNormal = simd_normalize(SIMD3<Float>(0.38, 0.3, -0.92))

    init() {
        root.addChild(camera)
        aim(from: camPos, at: [2.0, 1.6, 4.6])
        applySize(size)
    }

    // MARK: loading

    func load() async {
        do {
            let w = try await Task.detached(priority: .userInitiated) { try WorldLoader() }.value
            world = w
            let entity = try w.makeEntity()
            root.addChild(entity)
            bloom = BloomController(world: w)
            bloomed = Array(repeating: false, count: w.flowers.count)
            buildAtmosphere()
            buildFlowerFX(w)
            buildScreen()
            bloom?.update(dt: 0)
            loading = false
        } catch {
            loadError = "The forest couldn't grow on this device (\(error))."
        }
    }

    func start() {
        started = true
        audio.start()
        fly(to: places[0], quiet: true)
        Task { try? await Task.sleep(for: .seconds(2.2)); toast("Five flowers sleep around the arcade", "Find the glowing buds. Bring them close to wake them.", "You're the size of a ladybug") }
    }

    // MARK: frame

    func tick(_ dt: Float) {
        let dt = min(dt, 1 / 20)
        if abs(targetSize - size) / size > 0.002 { applySize(size * pow(targetSize / size, min(1, dt * 4))) }
        if var f = flight {
            f.t += dt / f.dur
            let k = f.t >= 1 ? 1 : 0.5 - 0.5 * cos(Float.pi * f.t)
            camPos = simd_mix(f.from, f.to, SIMD3(repeating: k))
            camera.transform.rotation = simd_slerp(f.fq, f.tq, k)
            camera.position = camPos
            flight = f.t >= 1 ? nil : f
            if flight == nil { syncAnglesFromCamera() }
        } else if !playing {
            let q = orientation
            let fwd = q.act([0, 0, -1]), right = q.act([1, 0, 0])
            let sp = 1.3 * size * dt
            camPos += fwd * move.y * sp + right * move.x * sp + SIMD3(0, lift * sp, 0)
            camera.transform.rotation = q
            camera.position = camPos
        }
        // flowers
        if let bloom {
            for (i, f) in bloom.flowers.enumerated() where f.phase == .dormant && started && flight == nil {
                let reach = max(0.7, f.splats.info.radius * 2.0)
                if simd_distance(camPos, f.center) < reach { trigger(i) }
            }
            bloom.update(dt: dt)
            for (i, b) in beacons.enumerated() { b.isEnabled = started && bloom.flowers[i].phase == .dormant }
        }
        // arcade
        if awake, screen != nil, let tex = screenTexture {
            screenClock += dt
            arcade.step(dt)
            if screenClock > 1 / 24 { screenClock = 0; if let img = arcade.render() { try? tex.replace(withImage: img, options: .init(semantic: .color)) } }
            let near = !playing && simd_distance(camPos, Self.screenCenter) < 1.2
            if near != nearScreen { nearScreen = near }
        }
    }

    private func trigger(_ i: Int) {
        guard let bloom, let world else { return }
        let f = bloom.flowers[i]
        bloom.bloom(f)
        bloomed[i] = true
        if i < bursts.count, var pe = bursts[i].components[ParticleEmitterComponent.self] { pe.burst(); bursts[i].components.set(pe) }
        haptic.impactOccurred(intensity: 0.9)
        audio.bloom(index: i)
        let name = flowerNames[world.flowers[i].info.id] ?? ("A flower", "")
        let left = bloomed.filter { !$0 }.count
        toast(name.0 + " blooms", name.1, left == 0 ? "Every flower is awake" : "\(bloomed.count - left) of \(bloomed.count)")
        if left == 0 { Task { try? await Task.sleep(for: .seconds(3.6)); wake() } }
    }

    private func wake() {
        awake = true
        audio.wake()
        haptic.impactOccurred(intensity: 1)
        if let screen { screen.isEnabled = true }
        toast("DARLA wakes up", "Walk up to the screen and press start.", "The arcade remembers")
        Task { try? await Task.sleep(for: .seconds(1.6)); fly(to: places[2], quiet: true) }
    }

    // MARK: camera

    var orientation: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0]) }

    func look(dx: Float, dy: Float) {
        guard flight == nil, !playing else { return }
        yaw -= dx * 0.005
        pitch = max(-1.45, min(1.45, pitch - dy * 0.005))
    }

    private func aim(from p: SIMD3<Float>, at t: SIMD3<Float>) {
        camPos = p
        camera.look(at: t, from: p, relativeTo: nil)
        syncAnglesFromCamera()
    }

    private func syncAnglesFromCamera() {
        let f = camera.transform.rotation.act([0, 0, -1])
        yaw = atan2(-f.x, -f.z)
        pitch = asin(max(-1, min(1, f.y)))
    }

    func fly(to p: Place, quiet: Bool = false) {
        let probe = Entity()
        probe.look(at: p.look, from: p.pos, relativeTo: nil)
        flight = (camPos, p.pos, camera.transform.rotation, probe.transform.rotation, 0, min(4, 1.6 + simd_distance(camPos, p.pos) * 0.45))
        setSize(p.size)
        if !quiet { toast(p.name, p.detail, "Travelling") }
    }

    func setSize(_ s: Float) { targetSize = max(0.01, min(6, s)) }
    func scaleSize(by k: Float) { setSize(targetSize * k) }

    private func applySize(_ s: Float) {
        size = s
        let fov = 78 - 20 * max(0, min(1, (log10(s) + 2) / 2.6))
        camera.camera.fieldOfViewInDegrees = fov
        camera.camera.near = max(0.0008, 0.012 * s)
        camera.camera.far = 400
        let name = s < 0.03 ? "Ant" : s < 0.12 ? "Ladybug" : s < 0.4 ? "Mouse" : s < 0.8 ? "Cat" : s < 2.5 ? "Human" : "Giant"
        sizeLabel = s < 1 ? "\(name) · \(Int(s * 100)) cm" : "\(name) · " + String(format: "%.1f m", s)
    }

    // MARK: arcade play

    func startGame() {
        playing = true; nearScreen = false
        arcade.begin()
        audio.coin()
        let eye = Self.screenCenter + Self.screenNormal * 0.5
        fly(to: .init(name: "", detail: "", size: 0.2, pos: eye, look: Self.screenCenter), quiet: true)
    }
    func tapArcade() { if playing { if arcade.flap() { audio.blip() } } }
    func stopGame() { playing = false; arcade.end() }

    // MARK: toast

    func toast(_ title: String, _ line: String, _ kicker: String) {
        toastTitle = title; toastLine = line; toastKicker = kicker; toastVisible = true
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toastVisible = false } }
    }

    // MARK: building the scene

    private func buildAtmosphere() {
        // sun motes drifting through the god rays
        let motes = Entity()
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [6, 4, 6]
        p.birthLocation = .volume
        p.speed = 0.02
        p.mainEmitter.birthRate = 260
        p.mainEmitter.lifeSpan = 9
        p.mainEmitter.size = 0.006
        p.mainEmitter.sizeVariation = 0.004
        p.mainEmitter.color = .constant(.single(UIColor(red: 1, green: 0.88, blue: 0.62, alpha: 0.9)))
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.noiseStrength = 0.03
        p.mainEmitter.noiseScale = 1.5
        p.mainEmitter.noiseAnimationSpeed = 0.2
        p.mainEmitter.opacityCurve = .gradualFadeInOut
        p.mainEmitter.isLightingEnabled = false
        motes.components.set(p)
        motes.position = [2.5, 2, 4.5]
        root.addChild(motes)

        // glass petals falling slowly through the light
        let petals = Entity()
        var q = ParticleEmitterComponent()
        q.emitterShape = .plane
        q.emitterShapeSize = [3.5, 0, 3.5]
        q.birthLocation = .surface
        q.emissionDirection = [0, -1, 0]
        q.speed = 0.06
        q.mainEmitter.birthRate = 6
        q.mainEmitter.lifeSpan = 22
        q.mainEmitter.size = 0.018
        q.mainEmitter.sizeVariation = 0.008
        q.mainEmitter.color = .evolving(start: .single(UIColor(red: 1, green: 0.84, blue: 0.9, alpha: 0.85)),
                                         end: .single(UIColor(red: 0.95, green: 0.9, blue: 1, alpha: 0.6)))
        q.mainEmitter.blendMode = .alpha
        q.mainEmitter.angularSpeed = 0.8
        q.mainEmitter.angularSpeedVariation = 0.8
        q.mainEmitter.noiseStrength = 0.08
        q.mainEmitter.noiseScale = 0.8
        q.mainEmitter.opacityCurve = .gradualFadeInOut
        q.mainEmitter.isLightingEnabled = false
        petals.components.set(q)
        petals.position = [2.2, 4.2, 4.7]
        root.addChild(petals)
    }

    private func buildFlowerFX(_ w: WorldLoader) {
        let palettes: [String: (UIColor, UIColor)] = [
            "peony": (UIColor(red: 1, green: 0.8, blue: 0.88, alpha: 1), UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)),
            "lily": (UIColor(red: 1, green: 1, blue: 0.94, alpha: 1), UIColor(red: 1, green: 0.72, blue: 0.6, alpha: 1)),
            "callas": (UIColor(white: 1, alpha: 1), UIColor(red: 1, green: 0.95, blue: 0.82, alpha: 1)),
            "glass": (UIColor(red: 1, green: 0.86, blue: 0.93, alpha: 1), UIColor(red: 0.95, green: 0.95, blue: 1, alpha: 1)),
            "orchids": (UIColor(red: 0.74, green: 0.72, blue: 1, alpha: 1), UIColor(red: 1, green: 0.66, blue: 0.9, alpha: 1)),
        ]
        for f in w.flowers {
            let c = f.center, r = f.info.radius
            let pal = palettes[f.info.id] ?? (.white, .white)
            // dormant beacon: a slow golden spiral of light around the bud
            let beacon = Entity()
            var b = ParticleEmitterComponent()
            b.emitterShape = .sphere
            b.emitterShapeSize = SIMD3(repeating: r * 0.45)
            b.birthLocation = .surface
            b.speed = 0.015
            b.mainEmitter.birthRate = 70
            b.mainEmitter.lifeSpan = 2.6
            b.mainEmitter.size = 0.007
            b.mainEmitter.sizeVariation = 0.004
            b.mainEmitter.color = .evolving(start: .single(UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 1)), end: .single(pal.0))
            b.mainEmitter.blendMode = .additive
            b.mainEmitter.vortexStrength = 0.6
            b.mainEmitter.noiseStrength = 0.02
            b.mainEmitter.opacityCurve = .gradualFadeInOut
            b.mainEmitter.isLightingEnabled = false
            beacon.components.set(b)
            beacon.position = c
            beacon.isEnabled = false
            root.addChild(beacon)
            beacons.append(beacon)
            // bloom burst: a one-shot swirl of petals and sparks rising out of the flower
            let burst = Entity()
            var e = ParticleEmitterComponent()
            e.emitterShape = .sphere
            e.emitterShapeSize = SIMD3(repeating: r * 0.35)
            e.birthLocation = .volume
            e.emissionDirection = [0, 1, 0]
            e.speed = 0.18
            e.speedVariation = 0.12
            e.isEmitting = false
            e.burstCount = 900
            e.burstCountVariation = 100
            e.mainEmitter.lifeSpan = 3.4
            e.mainEmitter.lifeSpanVariation = 1
            e.mainEmitter.size = 0.006
            e.mainEmitter.sizeVariation = 0.005
            e.mainEmitter.color = .evolving(start: .single(pal.0), end: .single(pal.1))
            e.mainEmitter.blendMode = .additive
            e.mainEmitter.spreadingAngle = 1.2
            e.mainEmitter.vortexStrength = 1.4
            e.mainEmitter.dampingFactor = 1.2
            e.mainEmitter.acceleration = [0, 0.04, 0]
            e.mainEmitter.noiseStrength = 0.05
            e.mainEmitter.opacityCurve = .quickFadeInOut
            e.mainEmitter.isLightingEnabled = false
            burst.components.set(e)
            burst.position = c
            root.addChild(burst)
            bursts.append(burst)
        }
    }

    private func buildScreen() {
        guard let img = arcade.render(),
              let tex = try? TextureResource(image: img, options: .init(semantic: .color)) else { return }
        screenTexture = tex
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white, texture: .init(tex))
        let plane = ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.58), materials: [mat])
        let pos = Self.screenCenter + Self.screenNormal * 0.035
        plane.look(at: pos - Self.screenNormal, from: pos, upVector: [0, 1, 0], relativeTo: nil)
        plane.isEnabled = false
        root.addChild(plane)
        screen = plane
        // soft neon spill in front of the glass
        let glow = Entity()
        var g = ParticleEmitterComponent()
        g.emitterShape = .plane
        g.emitterShapeSize = [0.45, 0, 0.5]
        g.birthLocation = .surface
        g.speed = 0.01
        g.mainEmitter.birthRate = 40
        g.mainEmitter.lifeSpan = 1.6
        g.mainEmitter.size = 0.004
        g.mainEmitter.color = .constant(.single(UIColor(red: 1, green: 0.45, blue: 0.75, alpha: 0.8)))
        g.mainEmitter.blendMode = .additive
        g.mainEmitter.isLightingEnabled = false
        glow.components.set(g)
        glow.position = pos + Self.screenNormal * 0.04
        glow.look(at: glow.position + [0, 1, 0], from: glow.position, relativeTo: nil)
        plane.addChild(glow, preservingWorldTransform: true)
    }
}
