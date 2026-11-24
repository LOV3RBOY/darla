import SwiftUI
import RealityKit
import UIKit
import simd

/// A place you can glide to. The camera orbits `focus` from `dist` away, at heading `theta` and elevation `phi` (degrees).
struct Place: Identifiable {
    let id: String
    let name: String
    let detail: String
    let focus: SIMD3<Float>
    let dist: Float
    let theta: Float
    let phi: Float
    var flower: Int? = nil
}

/// The whole living scene: camera, splat world, blooms, particles, the arcade.
@MainActor @Observable
final class Experience {
    enum Mode { case orbit, free }

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
    var size: Float = 0.5
    var sizeLabel = ""
    var mode: Mode = .orbit
    var focusID = "shrine"
    var touring = false
    var showCoach = true
    var places: [Place] = []

    let flowerNames = ["peony": ("The chrome peony", "Its mirrored petals catch the sun."),
                       "lily": ("The dew lily", "Every droplet lights up."),
                       "callas": ("The white callas", "They open like trumpets."),
                       "glass": ("The glass blossoms", "Light pours straight through them."),
                       "orchids": ("The orchids", "They unfurl overhead.")]

    // scene
    let root = Entity()
    let camera = PerspectiveCamera()
    let arcade = PetalRun()
    let audio = AudioDirector()
    @ObservationIgnored var updateSub: EventSubscription?
    @ObservationIgnored var viewSize = CGSize(width: 390, height: 844)
    @ObservationIgnored private var world: WorldLoader?
    @ObservationIgnored private var bloom: BloomController?
    @ObservationIgnored private var beacons: [Entity] = []
    @ObservationIgnored private var bursts: [Entity] = []
    @ObservationIgnored private var screen: ModelEntity?
    @ObservationIgnored private var screenTexture: TextureResource?
    @ObservationIgnored private var screenClock: Float = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var autopilot: Task<Void, Never>?
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .soft)

    // orbit camera (current + target, eased every frame)
    @ObservationIgnored private var focus = SIMD3<Float>(2.0, 1.5, 4.6)
    @ObservationIgnored private var focusT = SIMD3<Float>(2.0, 1.5, 4.6)
    @ObservationIgnored private var dist: Float = 3.2
    @ObservationIgnored private var distT: Float = 3.2
    @ObservationIgnored private var theta: Float = 125
    @ObservationIgnored private var thetaT: Float = 125
    @ObservationIgnored private var phi: Float = 12
    @ObservationIgnored private var phiT: Float = 12
    @ObservationIgnored private var spin: Float = 0
    @ObservationIgnored private var tilt: Float = 0
    @ObservationIgnored private var minDist: Float = 0.6
    @ObservationIgnored private var maxDist: Float = 4.5
    @ObservationIgnored private var arrivalArmed: Int?

    // free-fly camera
    @ObservationIgnored var stick = SIMD2<Float>(0, 0)
    @ObservationIgnored private var camPos = SIMD3<Float>(4.18, 2.3, 2.26)
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var pitch: Float = 0
    @ObservationIgnored private var velocity = SIMD3<Float>(0, 0, 0)

    static let screenCenter = SIMD3<Float>(1.885, 1.86, 4.59)
    static let screenNormal = simd_normalize(SIMD3<Float>(0.38, 0.3, -0.92))
    /// The filmed side of the shrine. Orbiting stays inside it so the world always looks its best.
    static let thetaRange: ClosedRange<Float> = 82...168

    init() {
        root.addChild(camera)
        camera.camera.far = 200
        applyOrbit(dt: 1)
    }

    // MARK: loading

    func load() async {
        do {
            let w = try await Task.detached(priority: .userInitiated) { try WorldLoader() }.value
            world = w
            let e = try w.makeEntities()
            root.addChild(e.world)
            root.addChild(e.flowers)
            bloom = BloomController(world: w)
            bloomed = Array(repeating: false, count: w.flowers.count)
            buildPlaces(w)
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
        if let s = places.first(where: { $0.id == "shrine" }) { go(to: s, quiet: true) }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            toast("Five flowers sleep around the arcade", "Tap a glowing bud to fly to it and wake it.", "Welcome to DARLA")
        }
    }

    private func buildPlaces(_ w: WorldLoader) {
        var list: [Place] = [Place(id: "shrine", name: "The shrine", detail: "The whole arcade at once", focus: [2.0, 1.5, 4.6], dist: 3.2, theta: 125, phi: 12)]
        for (i, f) in w.flowers.enumerated() {
            let r = f.info.radius
            let n = flowerNames[f.info.id] ?? (f.info.id, "")
            let phi: Float = f.info.id == "orchids" ? -28 : (f.info.id == "glass" ? 6 : 14)
            list.append(Place(id: f.info.id, name: n.0, detail: n.1, focus: f.center, dist: r * 1.9, theta: 128, phi: phi, flower: i))
        }
        let n = Self.screenNormal
        list.append(Place(id: "screen", name: "The arcade screen", detail: "Wakes when every flower blooms",
                          focus: Self.screenCenter, dist: 0.75, theta: atan2(n.x, n.z) * 180 / .pi, phi: asin(n.y) * 180 / .pi))
        places = list
    }

    // MARK: frame

    func tick(_ dt: Float) {
        let dt = min(dt, 1 / 20)
        if mode == .orbit || playing { applyOrbit(dt: dt) } else { applyFree(dt: dt) }

        if let bloom {
            if let i = arrivalArmed, simd_distance(focus, focusT) < 0.03, abs(dist - distT) < 0.15 {
                arrivalArmed = nil
                if bloom.flowers[i].phase == .dormant { trigger(i) }
            }
            if mode == .free && started {
                for (i, f) in bloom.flowers.enumerated() where f.phase == .dormant {
                    if simd_distance(camPos, f.center) < max(0.7, f.splats.info.radius * 2) { trigger(i) }
                }
            }
            bloom.update(dt: dt)
            for (i, b) in beacons.enumerated() { b.isEnabled = started && bloom.flowers[i].phase == .dormant }
        }

        if awake, let tex = screenTexture {
            screenClock += dt
            arcade.step(dt)
            if screenClock > 1 / 20 { screenClock = 0; if let img = arcade.render() { try? tex.replace(withImage: img, options: .init(semantic: .color)) } }
            let near = !playing && simd_distance(camera.position, Self.screenCenter) < 1.3
            if near != nearScreen { nearScreen = near }
        }
    }

    private func applyOrbit(dt: Float) {
        thetaT += spin; phiT += tilt
        let decay = pow(0.02, dt); spin *= decay; tilt *= decay
        thetaT = soft(thetaT, Self.thetaRange)
        phiT = max(-40, min(60, phiT))
        distT = max(minDist, min(maxDist, distT))
        let k = 1 - exp(-dt * 3.2), kr = 1 - exp(-dt * 9)
        focus += (focusT - focus) * k
        dist += (distT - dist) * k
        theta += (thetaT - theta) * kr
        phi += (phiT - phi) * kr
        let t = theta * .pi / 180, p = phi * .pi / 180
        var pos = focus + dist * SIMD3(cos(p) * sin(t), sin(p), cos(p) * cos(t))
        pos.y = max(0.015 + dist * 0.05, pos.y)
        camera.look(at: focus, from: pos, relativeTo: nil)
        setSize(dist * 0.3)
    }

    /// Pulls a value back inside the range with a soft spring instead of a hard wall.
    private func soft(_ v: Float, _ r: ClosedRange<Float>) -> Float {
        if v < r.lowerBound { return v + (r.lowerBound - v) * 0.2 }
        if v > r.upperBound { return v - (v - r.upperBound) * 0.2 }
        return v
    }

    private func applyFree(dt: Float) {
        let q = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        let fwd = q.act([0, 0, -1]), right = q.act([1, 0, 0])
        let target = (fwd * stick.y + right * stick.x) * 1.4 * size
        velocity += (target - velocity) * min(1, dt * (simd_length(target) > 0 ? 5 : 3))
        camPos += velocity * dt
        camPos.y = max(0.012 + 0.35 * size, min(9, camPos.y))
        let c = SIMD2<Float>(2.2, 4.4), d = SIMD2(camPos.x, camPos.z) - c, len = simd_length(d)
        if len > 4.6 { camPos.x = c.x + d.x * 4.6 / len; camPos.z = c.y + d.y * 4.6 / len }
        camera.transform.rotation = q
        camera.position = camPos
    }

    // MARK: input

    func drag(dx: Float, dy: Float) {
        guard !playing else { return }
        cancelAutopilot(); hideCoach()
        if mode == .orbit {
            thetaT -= dx * 0.25; phiT += dy * 0.18
            spin = -dx * 0.25 * 0.18; tilt = dy * 0.18 * 0.18
        } else {
            yaw -= dx * 0.0042; pitch = max(-1.45, min(1.45, pitch - dy * 0.0042))
        }
    }

    func zoom(by k: Float) {
        guard !playing else { return }
        cancelAutopilot(); hideCoach()
        if mode == .orbit { distT = distT * k } else { setSize(size * k) }
    }

    func setStick(_ v: SIMD2<Float>) {
        if simd_length(v) > 0.05 { cancelAutopilot(); hideCoach() }
        stick = v
    }

    private func hideCoach() { if showCoach { showCoach = false } }

    func toggleMode() {
        cancelAutopilot()
        if mode == .orbit {
            camPos = camera.position
            let f = camera.transform.rotation.act([0, 0, -1])
            yaw = atan2(-f.x, -f.z); pitch = asin(max(-1, min(1, f.y)))
            velocity = .zero
            mode = .free
            toast("Free flight", "Left thumb flies, right thumb looks.", "Mode")
        } else {
            mode = .orbit
            go(to: places.first { $0.id == focusID } ?? places[0], quiet: true)
            toast("Guided orbit", "Drag to circle, pinch to come closer.", "Mode")
        }
    }

    // MARK: travel

    func go(to p: Place, quiet: Bool = false) {
        if mode == .free { mode = .orbit }
        focusID = p.id
        focusT = p.focus
        distT = p.dist
        minDist = p.flower != nil ? p.dist * 0.45 : (p.id == "screen" ? 0.35 : 0.6)
        maxDist = p.flower != nil ? p.dist * 3.5 : 4.5
        thetaT = min(max(p.theta, Self.thetaRange.lowerBound), Self.thetaRange.upperBound)
        phiT = p.phi
        arrivalArmed = p.flower
        if !quiet { toast(p.name, p.detail, "Travelling") }
    }

    /// Projects a world point into view coordinates (points). nil when behind the camera.
    func project(_ w: SIMD3<Float>) -> CGPoint? {
        let v = camera.transform.rotation.inverse.act(w - camera.position)
        guard v.z < -0.01 else { return nil }
        let t = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        let aspect = Float(viewSize.width / max(1, viewSize.height))
        let nx = v.x / (-v.z * t * aspect), ny = v.y / (-v.z * t)
        return CGPoint(x: CGFloat((nx + 1) / 2) * viewSize.width, y: CGFloat((1 - ny) / 2) * viewSize.height)
    }

    /// Tap: glide to the nearest glowing bud (or the screen) under your finger.
    func tap(at pt: CGPoint) {
        if playing { tapArcade(); return }
        var best: (Place, CGFloat)?
        for p in places where p.id != "shrine" {
            if p.id == "screen" && !awake { continue }
            guard let s = project(p.focus) else { continue }
            let d = hypot(s.x - pt.x, s.y - pt.y)
            if d < 110, d < (best?.1 ?? .infinity) { best = (p, d) }
        }
        if let b = best { cancelAutopilot(); hideCoach(); go(to: b.0) }
    }

    func startTour() {
        cancelAutopilot()
        touring = true; hideCoach()
        autopilot = Task { [weak self] in
            guard let self else { return }
            for p in self.places where p.flower != nil {
                if Task.isCancelled { break }
                if let f = p.flower, self.bloomed[f] { continue }
                self.go(to: p, quiet: true)
                try? await Task.sleep(for: .seconds(4))
                for _ in 0..<40 { if Task.isCancelled { break }; self.thetaT -= 0.45; try? await Task.sleep(for: .milliseconds(60)) }
            }
            if !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.5))
                if self.awake, let s = self.places.first(where: { $0.id == "screen" }) { self.go(to: s, quiet: true) }
            }
            self.touring = false
        }
    }

    func cancelAutopilot() {
        if autopilot != nil { autopilot?.cancel(); autopilot = nil; touring = false }
    }

    // MARK: blooming and waking

    private func trigger(_ i: Int) {
        guard let bloom, let world else { return }
        bloom.bloom(bloom.flowers[i])
        bloomed[i] = true
        if i < bursts.count, var pe = bursts[i].components[ParticleEmitterComponent.self] { pe.burst(); bursts[i].components.set(pe) }
        haptic.impactOccurred(intensity: 0.9)
        audio.bloom(index: i)
        let name = flowerNames[world.flowers[i].info.id] ?? ("A flower", "")
        let left = bloomed.filter { !$0 }.count
        toast(name.0 + " blooms", name.1, left == 0 ? "Every flower is awake" : "\(bloomed.count - left) of \(bloomed.count)")
        if left == 0 { Task { try? await Task.sleep(for: .seconds(4)); wake() } }
    }

    private func wake() {
        awake = true
        audio.wake()
        haptic.impactOccurred(intensity: 1)
        screen?.isEnabled = true
        toast("DARLA wakes up", "Glide to the screen and press start.", "The arcade remembers")
        Task { try? await Task.sleep(for: .seconds(1.6)); if let s = places.first(where: { $0.id == "screen" }) { go(to: s, quiet: true) } }
    }

    // MARK: size

    private func setSize(_ s: Float) {
        let s = max(0.01, min(6, s))
        guard abs(s - size) / max(size, 0.001) > 0.01 || sizeLabel.isEmpty else { return }
        size = s
        camera.camera.fieldOfViewInDegrees = 78 - 20 * max(0, min(1, (log10(s) + 2) / 2.6))
        camera.camera.near = max(0.0008, 0.012 * s)
        let name = s < 0.03 ? "Ant" : s < 0.12 ? "Ladybug" : s < 0.4 ? "Mouse" : s < 0.8 ? "Cat" : s < 2.5 ? "Human" : "Giant"
        sizeLabel = s < 1 ? "\(name) · \(Int(s * 100)) cm" : "\(name) · " + String(format: "%.1f m", s)
    }

    /// Size rail: in orbit it sets how close you are; in free flight it sets your scale.
    func setSizeFromRail(_ s: Float) {
        cancelAutopilot()
        if mode == .orbit { distT = s / 0.3 } else { setSize(s) }
    }

    // MARK: arcade play

    func startGame() {
        playing = true; nearScreen = false
        arcade.begin()
        audio.coin()
        if let s = places.first(where: { $0.id == "screen" }) { go(to: Place(id: "screen", name: s.name, detail: "", focus: s.focus, dist: 0.5, theta: s.theta, phi: s.phi), quiet: true) }
    }
    func tapArcade() { if playing, arcade.flap() { audio.blip() } }
    func stopGame() { playing = false; arcade.end() }

    // MARK: toast

    func toast(_ title: String, _ line: String, _ kicker: String) {
        toastTitle = title; toastLine = line; toastKicker = kicker; toastVisible = true
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toastVisible = false } }
    }

    // MARK: building the scene

    private func buildAtmosphere() {
        let motes = Entity()
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [6, 4, 6]
        p.birthLocation = .volume
        p.speed = 0.02
        p.mainEmitter.birthRate = 160
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

        let petals = Entity()
        var q = ParticleEmitterComponent()
        q.emitterShape = .plane
        q.emitterShapeSize = [3.5, 0, 3.5]
        q.birthLocation = .surface
        q.emissionDirection = [0, -1, 0]
        q.speed = 0.06
        q.mainEmitter.birthRate = 5
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
            let beacon = Entity()
            var b = ParticleEmitterComponent()
            b.emitterShape = .sphere
            b.emitterShapeSize = SIMD3(repeating: r * 0.45)
            b.birthLocation = .surface
            b.speed = 0.015
            b.mainEmitter.birthRate = 60
            b.mainEmitter.lifeSpan = 2.6
            b.mainEmitter.size = 0.008
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

            let burst = Entity()
            var e = ParticleEmitterComponent()
            e.emitterShape = .sphere
            e.emitterShapeSize = SIMD3(repeating: r * 0.35)
            e.birthLocation = .volume
            e.emissionDirection = [0, 1, 0]
            e.speed = 0.18
            e.speedVariation = 0.12
            e.isEmitting = false
            e.burstCount = 700
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
    }
}
