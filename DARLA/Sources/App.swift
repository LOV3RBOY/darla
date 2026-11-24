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
    @State private var lastDrag: CGSize = .zero
    @State private var pinchBase: Float = 1
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
            .gesture(lookGesture)
            .simultaneousGesture(sizeGesture)
            .simultaneousGesture(SpatialTapGesture().onEnded { _ in exp.tapArcade() })

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

    private var lookGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                lastDrag = v.translation
                exp.look(dx: Float(d.width), dy: Float(d.height))
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var sizeGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == 1 { pinchBase = exp.size }
                exp.setSize(pinchBase / Float(v.magnification))
            }
            .onEnded { _ in pinchBase = 1 }
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
        VStack {
            HStack(alignment: .top) {
                QuestCard(exp: exp)
                Spacer()
                Button { showPlaces = true } label: {
                    Image(systemName: "sparkles").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.ink).frame(width: 48, height: 48)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Spacer()
            if exp.nearScreen {
                Button { exp.startGame() } label: {
                    Text("PRESS START").font(.system(size: 15, weight: .black, design: .monospaced)).kerning(3)
                        .foregroundStyle(.white).padding(.horizontal, 30).padding(.vertical, 16)
                }
                .glassEffect(.regular.tint(Palette.neon.opacity(0.7)).interactive(), in: .capsule)
                .shadow(color: Palette.neon.opacity(0.8), radius: 22)
                .padding(.bottom, 24)
                .transition(.scale.combined(with: .opacity))
            }
            HStack(alignment: .bottom) {
                MovePad(exp: exp)
                Spacer()
                SizeRail(exp: exp)
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
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

/// Hold-to-move arrows (forward, back, turn-strafe) in a single glass disc.
struct MovePad: View {
    let exp: Experience
    var body: some View {
        ZStack {
            Circle().fill(.clear).frame(width: 148, height: 148).glassEffect(.regular, in: .circle)
            HoldArrow(symbol: "chevron.up") { exp.move.y = $0 ? 1 : 0 }.offset(y: -46)
            HoldArrow(symbol: "chevron.down") { exp.move.y = $0 ? -1 : 0 }.offset(y: 46)
            HoldArrow(symbol: "chevron.left") { exp.move.x = $0 ? -1 : 0 }.offset(x: -46)
            HoldArrow(symbol: "chevron.right") { exp.move.x = $0 ? 1 : 0 }.offset(x: 46)
            Circle().fill(Palette.sun.opacity(0.85)).frame(width: 8, height: 8).shadow(color: Palette.sun, radius: 6)
        }
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
    private let h: CGFloat = 210
    var body: some View {
        VStack(spacing: 10) {
            HoldArrow(symbol: "arrow.up") { exp.lift = $0 ? 1 : 0 }.glassEffect(.regular, in: .circle)
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
                exp.setSize(0.01 * pow(600, f))
            })
            HoldArrow(symbol: "arrow.down") { exp.lift = $0 ? -1 : 0 }.glassEffect(.regular, in: .circle)
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
                ForEach(exp.places) { p in
                    Button { show = false; exp.fly(to: p) } label: {
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
