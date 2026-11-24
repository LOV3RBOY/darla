import SwiftUI
import RealityKit

@main
struct DarlaApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup { RootView().preferredColorScheme(.dark).statusBarHidden() }
    }
}

enum Palette {
    static let sun = Color(red: 0.96, green: 0.75, blue: 0.42)
    static let orchid = Color(red: 0.73, green: 0.65, blue: 1)
    static let neon = Color(red: 1, green: 0.37, blue: 0.64)
    static let ink = Color(red: 0.95, green: 0.94, blue: 0.9)
    static let moss = Color(red: 0.03, green: 0.05, blue: 0.035)
}

extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font { .system(size: size, weight: weight, design: .serif) }
}

struct RootView: View {
    @State private var exp = Experience()
    @State private var showPlaces = false

    var body: some View {
        ZStack {
            Palette.moss.ignoresSafeArea()
            RealityView { content in
                content.camera = .virtual
                content.add(exp.root)
                exp.updateSub = content.subscribe(to: SceneEvents.Update.self) { e in
                    MainActor.assumeIsolated { exp.tick(Float(e.deltaTime)) }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !exp.loading && exp.started { TouchLayer(exp: exp).ignoresSafeArea() }

            if !exp.loading && exp.started && !exp.playing { HUD(exp: exp, showPlaces: $showPlaces).transition(.opacity) }
            if exp.playing { ArcadeOverlay(exp: exp) }
            ToastView(exp: exp)
            if exp.loading || !exp.started { Intro(exp: exp).transition(.opacity.combined(with: .scale(scale: 1.04))) }
        }
        .animation(.easeInOut(duration: 0.9), value: exp.started)
        .animation(.easeInOut(duration: 0.6), value: exp.loading)
        .animation(.spring(duration: 0.5), value: exp.nearScreen)
        .sheet(isPresented: $showPlaces) { PlacesSheet(exp: exp, show: $showPlaces).presentationDetents([.medium]).presentationBackground(.ultraThinMaterial) }
        .task { await exp.load() }
    }

}

// MARK: - Intro / loading

struct Intro: View {
    let exp: Experience
    @State private var breathe = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Palette.moss, Color(red: 0.07, green: 0.1, blue: 0.06)], startPoint: .top, endPoint: .bottom)
                .opacity(exp.loading ? 1 : 0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Text("DARLA").font(.display(64, .ultraLight)).kerning(14).foregroundStyle(Palette.ink)
                    .shadow(color: Palette.sun.opacity(breathe ? 0.5 : 0.15), radius: 24)
                Text("an arcade the forest took back").font(.display(17).italic()).foregroundStyle(Palette.ink.opacity(0.7))
                Spacer()
                if let err = exp.loadError {
                    Text(err).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 40)
                } else if exp.loading {
                    Capsule().fill(LinearGradient(colors: [Palette.orchid, Palette.sun], startPoint: .leading, endPoint: .trailing))
                        .frame(width: breathe ? 160 : 40, height: 2).opacity(0.9)
                    Text("Growing the forest").font(.footnote).foregroundStyle(.white.opacity(0.55))
                } else {
                    Button { exp.start() } label: {
                        Text("Enter the forest").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 34).padding(.vertical, 16)
                    }
                    .glassEffect(.regular.tint(Palette.sun.opacity(0.25)).interactive(), in: .capsule)
                    Text("Sound on. Drag to look, pinch to change your size.").font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                Spacer().frame(height: 70)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { breathe = true } }
    }
}

// MARK: - HUD

struct HUD: View {
    let exp: Experience
    @Binding var showPlaces: Bool
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                QuestCard(exp: exp)
                Spacer()
                VStack(spacing: 10) {
                    RoundButton(symbol: exp.mode == .orbit ? "scope" : "airplane") { exp.toggleMode() }
                    RoundButton(symbol: "list.bullet") { showPlaces = true }
                }
            }
            Spacer()
            if exp.nearScreen {
                Button { exp.startGame() } label: {
                    Text("PRESS START").font(.system(size: 15, weight: .black, design: .monospaced)).kerning(3)
                        .foregroundStyle(.white).padding(.horizontal, 30).padding(.vertical, 16)
                }
                .glassEffect(.regular.tint(Palette.neon.opacity(0.7)).interactive(), in: .capsule)
                .shadow(color: Palette.neon.opacity(0.8), radius: 22)
                .transition(.scale.combined(with: .opacity))
            }
            HStack(alignment: .bottom) {
                GuideButton(exp: exp)
                Spacer()
                SizeRail(exp: exp)
            }
            PlaceStrip(exp: exp)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }
}

/// Destinations as cards: tap to glide there. Sleeping flowers glow, bloomed ones show a sun dot.
struct PlaceStrip: View {
    let exp: Experience
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(exp.places) { p in
                    let locked = p.id == "screen" && !exp.awake
                    let done = p.flower.map { exp.bloomed.indices.contains($0) && exp.bloomed[$0] } ?? false
                    Button { if !locked { exp.cancelAutopilot(); exp.go(to: p) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(p.id, locked)).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(done ? Palette.sun : (p.flower != nil ? Palette.orchid : Palette.ink))
                            Text(short(p)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.opacity(locked ? 0.4 : 1))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                    .glassEffect(exp.focusID == p.id ? .regular.tint(Palette.sun.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                    .disabled(locked)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
    private func short(_ p: Place) -> String { p.name.replacingOccurrences(of: "The ", with: "").capitalized }
    private func icon(_ id: String, _ locked: Bool) -> String {
        switch id { case "shrine": return "house"; case "screen": return locked ? "lock.fill" : "gamecontroller.fill"; default: return "camera.macro" }
    }
}

struct QuestCard: View {
    let exp: Experience
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exp.awake ? "DARLA is awake" : "Wake the arcade").font(.display(19, .regular)).foregroundStyle(Palette.ink)
            HStack(spacing: 9) {
                ForEach(exp.bloomed.indices, id: \.self) { i in PetalPip(on: exp.bloomed[i]) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct PetalPip: View {
    let on: Bool
    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { k in
                Capsule().fill(on ? Palette.sun : Color.white.opacity(0.22)).frame(width: 5, height: 9)
                    .offset(y: -4.5).rotationEffect(.degrees(Double(k) * 72))
            }
            Circle().fill(on ? Color.white : Color.white.opacity(0.35)).frame(width: 4, height: 4)
        }
        .frame(width: 20, height: 20)
        .shadow(color: on ? Palette.sun : .clear, radius: on ? 8 : 0)
        .scaleEffect(on ? 1.12 : 1)
        .animation(.spring(duration: 0.7, bounce: 0.5), value: on)
    }
}

struct HoldArrow: View {
    let symbol: String
    let set: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(down ? Palette.sun : Palette.ink.opacity(0.9))
            .frame(width: 52, height: 52).contentShape(Rectangle())
            .scaleEffect(down ? 0.88 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; set(true); UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
                .onEnded { _ in down = false; set(false) })
            .animation(.spring(duration: 0.25), value: down)
    }
}

/// The standout control: a glowing vertical rail that sets your size from ant to giant, with rise/sink buttons.
struct SizeRail: View {
    let exp: Experience
    private let h: CGFloat = 170
    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.clear).frame(width: 46, height: h).glassEffect(.regular, in: .capsule)
                Capsule().fill(LinearGradient(colors: [Palette.sun.opacity(0.9), Palette.orchid.opacity(0.5)], startPoint: .bottom, endPoint: .top))
                    .frame(width: 4, height: max(8, h * frac - 10)).padding(.bottom, 6)
                Circle().fill(Palette.sun).frame(width: 22, height: 22).shadow(color: Palette.sun, radius: 12)
                    .offset(y: -(h - 30) * frac - 4)
            }
            .overlay(alignment: .leading) {
                VStack { Text("Giant"); Spacer(); Text(exp.sizeLabel).foregroundStyle(Palette.sun); Spacer(); Text("Ant") }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .frame(height: h - 16).fixedSize().offset(x: -78)
                    .multilineTextAlignment(.trailing)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = Float(1 - max(0, min(1, v.location.y / h)))
                exp.setSizeFromRail(0.01 * pow(600, f))
            })
        }
    }
    private var frac: CGFloat { CGFloat(log(Double(exp.size) / 0.01) / log(600)) }
}

// MARK: - Toast, places, arcade

struct ToastView: View {
    let exp: Experience
    var body: some View {
        VStack(spacing: 8) {
            Text(exp.toastKicker).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.sun)
            Text(exp.toastTitle).font(.display(30)).foregroundStyle(.white).multilineTextAlignment(.center)
            if !exp.toastLine.isEmpty { Text(exp.toastLine).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center) }
        }
        .padding(.horizontal, 30)
        .shadow(color: .black.opacity(0.8), radius: 18)
        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 150)
        .opacity(exp.toastVisible ? 1 : 0)
        .offset(y: exp.toastVisible ? 0 : -10)
        .animation(.easeInOut(duration: 0.8), value: exp.toastVisible)
        .allowsHitTesting(false)
    }
}

struct PlacesSheet: View {
    let exp: Experience
    @Binding var show: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Travel").font(.display(28)).padding(.bottom, 10)
                ForEach(exp.places.filter { $0.id != "screen" || exp.awake }) { p in
                    Button { show = false; exp.cancelAutopilot(); exp.go(to: p) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.display(20, .regular)).foregroundStyle(Palette.ink)
                                Text(p.detail).font(.footnote).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(Palette.sun)
                        }
                        .padding(.vertical, 14)
                    }
                    Divider().opacity(0.3)
                }
            }
            .padding(24)
        }
    }
}

struct ArcadeOverlay: View {
    let exp: Experience
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button { exp.stopGame() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 46, height: 46)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Spacer()
            Text("Tap anywhere to flap").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.bottom, 30)
        }
        .padding(18)
    }
}


// MARK: - Touch: floating joystick (left), look (right), tap to glide, pinch to resize

struct TouchLayer: View {
    let exp: Experience
    @State private var origin: CGPoint?
    @State private var knob: CGPoint = .zero
    @State private var last: CGSize = .zero
    @State private var pinchLast: CGFloat = 1
    private let radius: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if exp.playing {
                    Color.clear.contentShape(Rectangle()).onTapGesture { exp.tapArcade() }
                } else if exp.mode == .orbit {
                    // one finger: circle around what you're looking at. tap: glide to a glowing bud.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { v in
                                exp.drag(dx: Float(v.translation.width - last.width), dy: Float(v.translation.height - last.height))
                                last = v.translation
                            }
                            .onEnded { _ in last = .zero })
                        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("touch")).onEnded { e in exp.tap(at: e.location) })
                } else {
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .frame(width: geo.size.width * 0.46)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("touch"))
                                .onChanged { v in
                                    if origin == nil { origin = v.startLocation; UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5) }
                                    var d = CGSize(width: v.location.x - origin!.x, height: v.location.y - origin!.y)
                                    let m = hypot(d.width, d.height)
                                    if m > radius { d.width *= radius / m; d.height *= radius / m }
                                    knob = CGPoint(x: d.width, y: d.height)
                                    let nx = Float(d.width / radius), ny = Float(-d.height / radius)
                                    let mag = min(1, sqrt(nx * nx + ny * ny)), curved = mag * mag * 0.65 + mag * 0.35
                                    exp.setStick(mag > 0.001 ? SIMD2(nx, ny) / mag * curved : .zero)
                                }
                                .onEnded { _ in origin = nil; knob = .zero; exp.setStick(.zero) })
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3)
                                .onChanged { v in
                                    exp.drag(dx: Float(v.translation.width - last.width), dy: Float(v.translation.height - last.height))
                                    last = v.translation
                                }
                                .onEnded { _ in last = .zero })
                    }
                    if let o = origin {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.5).frame(width: radius * 2, height: radius * 2)
                                .background(Circle().fill(.white.opacity(0.06)))
                            Circle().fill(.white.opacity(0.85)).frame(width: 44, height: 44)
                                .shadow(color: Palette.sun.opacity(0.7), radius: 12)
                                .offset(x: knob.x, y: knob.y)
                        }
                        .position(o).allowsHitTesting(false)
                    }
                }
                if exp.showCoach && !exp.touring && !exp.playing { Coach(orbit: exp.mode == .orbit).allowsHitTesting(false) }
            }
            .coordinateSpace(.named("touch"))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let k = Float(pinchLast / max(0.2, v.magnification)); pinchLast = v.magnification
                    exp.zoom(by: k)
                }
                .onEnded { _ in pinchLast = 1 })
            .onAppear { exp.viewSize = geo.size }
            .onChange(of: geo.size) { _, s in exp.viewSize = s }
        }
    }
}

struct Coach: View {
    let orbit: Bool
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 34) {
                tip("hand.draw.fill", orbit ? "Drag to circle" : "Left thumb flies")
                tip("hand.pinch.fill", "Pinch to get close")
                tip("hand.tap.fill", "Tap a glow to travel")
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.7), radius: 10)
        .frame(maxHeight: .infinity, alignment: .center).offset(y: 40)
    }
    private func tip(_ s: String, _ t: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: s).font(.system(size: 26)).symbolEffect(.pulse)
            Text(t).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).frame(width: 86)
        }
    }
}

struct RoundButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink).frame(width: 48, height: 48)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// One-tap autopilot: glides from bud to bud, blooming each, then to the arcade.
struct GuideButton: View {
    let exp: Experience
    var body: some View {
        Button { exp.touring ? exp.cancelAutopilot() : exp.startTour() } label: {
            HStack(spacing: 10) {
                Image(systemName: exp.touring ? "pause.fill" : "sparkles")
                Text(exp.touring ? "Exploring…" : "Guide me").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(exp.touring ? Color.black : Palette.ink)
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .glassEffect(exp.touring ? .regular.tint(Palette.sun).interactive() : .regular.interactive(), in: .capsule)
        .animation(.spring(duration: 0.4), value: exp.touring)
    }
}
