import AVFoundation

/// All sound is synthesized: a warm forest bed, crystalline bloom chords, and 8-bit arcade cues.
final class AudioDirector {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let bed = AVAudioPlayerNode()
    private var voices: [AVAudioPlayerNode] = []
    private var next = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var running = false

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        // iOS stops the engine on interruptions/route changes; restart instead of crashing on the next sound
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, .AVAudioEngineConfigurationChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.revive() }
        }
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 38
        engine.attach(reverb); engine.attach(bed)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(bed, to: engine.mainMixerNode, format: format)
        for _ in 0..<10 {
            let v = AVAudioPlayerNode(); engine.attach(v); engine.connect(v, to: reverb, format: format); voices.append(v)
        }
    }

    func start() {
        guard !running else { return }
        do { try AVAudioSession.sharedInstance().setActive(true); try engine.start() } catch { return }
        running = true
        let b = makeBed(); bedBuffer = b
        bed.scheduleBuffer(b, at: nil, options: .loops)
        bed.volume = 0.55
        bed.play()
    }

    private func revive() {
        guard running else { return }
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        if engine.isRunning && !bed.isPlaying {
            bed.scheduleBuffer(bedBuffer ?? makeBed(), at: nil, options: .loops); bed.play()
        }
    }

    private var bedBuffer: AVAudioPCMBuffer?

    private func play(_ buf: AVAudioPCMBuffer, volume: Float = 1) {
        guard running else { return }
        if !engine.isRunning { revive() }
        guard engine.isRunning else { return }
        let v = voices[next]; next = (next + 1) % voices.count
        v.volume = volume
        v.scheduleBuffer(buf, at: nil, options: .interrupts)
        v.play()
    }

    private static let pent: [Double] = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66, 1318.5]

    func bloom(index: Int) {
        // a rising three-note chord, each note a soft glass bell
        for (k, step) in [0, 2, 4, 7].enumerated() {
            let f = Self.pent[(index + step) % Self.pent.count] * (index + step >= Self.pent.count ? 2 : 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.12) { self.play(self.bell(f, dur: 2.6), volume: 0.55) }
        }
    }

    func wake() {
        for (k, f) in [523.0, 659, 784, 1046, 784, 1046, 1318].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.13) { self.play(self.square(f, dur: 0.18), volume: 0.18) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.play(self.bell(261.6, dur: 4), volume: 0.7) }
    }

    func coin() { play(square(988, dur: 0.08), volume: 0.2); DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { self.play(self.square(1319, dur: 0.22), volume: 0.2) } }
    func blip() { play(square(880, dur: 0.06), volume: 0.12) }

    // MARK: synthesis

    private func buffer(_ seconds: Double, _ fill: (Int, Double) -> Float) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        for i in 0..<Int(n) { let s = fill(i, Double(i) / format.sampleRate); l[i] = s; r[i] = s }
        return b
    }

    private func bell(_ f: Double, dur: Double) -> AVAudioPCMBuffer {
        buffer(dur) { _, t in
            let env = min(1, t * 120) * exp(-t * 2.2)
            let s = sin(2 * .pi * f * t) * 0.6 + sin(2 * .pi * f * 2.01 * t) * 0.22 * exp(-t * 3) + sin(2 * .pi * f * 3.02 * t) * 0.1 * exp(-t * 5)
            return Float(s * env * 0.5)
        }
    }

    private func square(_ f: Double, dur: Double) -> AVAudioPCMBuffer {
        buffer(dur) { _, t in Float((sin(2 * .pi * f * t) >= 0 ? 1 : -1) * exp(-t * 6) * 0.25) }
    }

    /// 8-second seamless loop: filtered breeze plus a slow, warm chord.
    private func makeBed() -> AVAudioPCMBuffer {
        var b0 = 0.0, b1 = 0.0, lp = 0.0
        let chord: [Double] = [130.81, 196.0, 261.63, 329.63]
        return buffer(8) { i, t in
            let w = Double.random(in: -1...1)
            b0 = 0.997 * b0 + w * 0.03; b1 = 0.985 * b1 + w * 0.032
            lp += ((b0 + b1) - lp) * 0.06
            let swell = 0.5 + 0.5 * sin(2 * .pi * t / 8)
            var pad = 0.0
            for (k, f) in chord.enumerated() { pad += sin(2 * .pi * f * t + Double(k)) * (0.5 + 0.5 * sin(2 * .pi * t / 8 + Double(k))) }
            return Float(lp * 0.5 * (0.7 + 0.3 * swell) + pad * 0.012)
        }
    }
}
