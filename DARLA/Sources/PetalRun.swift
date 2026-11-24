import CoreGraphics
import UIKit

/// The tiny game that lives on DARLA's CRT: flap a petal through gaps in the vines.
final class PetalRun {
    private let W = 224, H = 256
    private var on = false, dead = false
    private var y: CGFloat = 120, vy: CGFloat = 0, t: CGFloat = 0, clock: CGFloat = 0
    private var pipes: [(x: CGFloat, gap: CGFloat, scored: Bool)] = []
    private(set) var score = 0
    private(set) var best = UserDefaults.standard.integer(forKey: "darla.best")
    private let ctx: CGContext?

    init() {
        ctx = CGContext(data: nil, width: 224, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .none
    }

    func begin() { on = true; reset() }
    func end() { on = false }
    private func reset() { y = 120; vy = 0; t = 0; pipes = []; score = 0; dead = false }

    /// returns true if it made a sound-worthy flap
    func flap() -> Bool {
        guard on else { return false }
        if dead { reset(); return false }
        vy = -2.9; return true
    }

    func step(_ dtf: Float) {
        let dt = CGFloat(dtf); clock += dt
        guard on, !dead else { return }
        t += dt; vy += 9 * dt; y += vy * 60 * dt
        if t > 1.35 { t = 0; pipes.append((CGFloat(W + 10), 60 + CGFloat.random(in: 0...120), false)) }
        for i in pipes.indices {
            pipes[i].x -= 70 * dt
            if !pipes[i].scored && pipes[i].x < 60 { pipes[i].scored = true; score += 1 }
        }
        pipes.removeAll { $0.x < -30 }
        let hit = y < 6 || y > CGFloat(H - 6) || pipes.contains { $0.x < 72 && $0.x > 44 && abs(y - $0.gap) > 34 }
        if hit {
            dead = true
            if score > best { best = score; UserDefaults.standard.set(best, forKey: "darla.best") }
        }
    }

    func render() -> CGImage? {
        guard let c = ctx else { return nil }
        // CoreGraphics is y-up: flip so we can draw top-down like a CRT
        c.saveGState(); c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
        c.setFillColor(UIColor(red: 0.03, green: 0.02, blue: 0.05, alpha: 1).cgColor)
        c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for i in 0..<34 {
            let x = (CGFloat(i * 53) + clock * 18 * CGFloat(1 + i % 3)).truncatingRemainder(dividingBy: CGFloat(W))
            c.setFillColor((i % 4 == 0 ? UIColor(red: 1, green: 0.82, blue: 0.9, alpha: 1) : UIColor(red: 0.23, green: 0.16, blue: 0.33, alpha: 1)).cgColor)
            c.fill(CGRect(x: CGFloat(W) - x, y: CGFloat((i * 97) % H), width: 2, height: 2))
        }
        if !on {
            text("DARLA", y: 78, size: 30, color: UIColor(red: 1, green: 0.37, blue: 0.64, alpha: 1), c)
            text("PETAL RUN", y: 112, size: 10, color: UIColor(red: 0.73, green: 0.65, blue: 1, alpha: 1), c)
            for i in 0..<5 { flower(c, CGFloat(40 + i * 36), 150 + sin(clock * 2 + CGFloat(i)) * 6, i, 0) }
            if Int(clock * 2) % 2 == 1 { text("PRESS START", y: 200, size: 10, color: .white, c) }
            text("HI \(best)", y: 228, size: 9, color: UIColor(red: 0.96, green: 0.75, blue: 0.42, alpha: 1), c)
        } else {
            for p in pipes {
                c.setFillColor(UIColor(red: 0.18, green: 0.48, blue: 0.24, alpha: 1).cgColor)
                c.fill(CGRect(x: p.x, y: 0, width: 22, height: p.gap - 34)); c.fill(CGRect(x: p.x, y: p.gap + 34, width: 22, height: CGFloat(H)))
                c.setFillColor(UIColor(red: 0.42, green: 0.83, blue: 0.44, alpha: 1).cgColor)
                c.fill(CGRect(x: p.x - 2, y: p.gap - 40, width: 26, height: 6)); c.fill(CGRect(x: p.x - 2, y: p.gap + 34, width: 26, height: 6))
            }
            flower(c, 60, y, 0, vy * 0.15)
            text("\(score)", y: 22, size: 18, color: .white, c)
            if dead {
                text("GAME OVER", y: 112, size: 14, color: UIColor(red: 1, green: 0.37, blue: 0.64, alpha: 1), c)
                text("TAP TO RETRY", y: 140, size: 9, color: .white, c)
            }
        }
        c.setFillColor(UIColor(white: 0, alpha: 0.25).cgColor)
        for yy in stride(from: 0, to: H, by: 3) { c.fill(CGRect(x: 0, y: yy, width: W, height: 1)) }
        c.restoreGState()
        return c.makeImage()
    }

    private func flower(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ k: Int, _ rot: CGFloat) {
        let cols: [UIColor] = [UIColor(red: 1, green: 0.56, blue: 0.72, alpha: 1), .white, UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1),
                               UIColor(red: 1, green: 0.79, blue: 0.88, alpha: 1), UIColor(red: 0.66, green: 0.61, blue: 1, alpha: 1)]
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: rot)
        c.setFillColor(cols[k % 5].cgColor)
        for _ in 0..<5 { c.rotate(by: .pi * 2 / 5); c.fill(CGRect(x: -3, y: -10, width: 6, height: 8)) }
        c.setFillColor(UIColor(red: 0.96, green: 0.75, blue: 0.42, alpha: 1).cgColor); c.fill(CGRect(x: -3, y: -3, width: 6, height: 6))
        c.restoreGState()
    }

    private func text(_ s: String, y: CGFloat, size: CGFloat, color: UIColor, _ c: CGContext) {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .black)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let w = a.size().width
        // the context is already flipped top-down (UIKit convention), so UIKit text draws upright
        UIGraphicsPushContext(c)
        a.draw(at: CGPoint(x: (CGFloat(W) - w) / 2, y: y - size * 0.6))
        UIGraphicsPopContext()
    }
}
