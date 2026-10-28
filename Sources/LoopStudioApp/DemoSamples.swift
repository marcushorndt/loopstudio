import Foundation
import LoopStudioEngine

/// Synthesized loops and one-shots, so the app makes sound on the first start. All at 120 BPM, 48 kHz.
enum DemoSamples {
    static let rate = 48_000.0
    static let beat = 24_000
    static let bar = 96_000

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoopStudio/Demo Samples", isDirectory: true)
    }

    /// Writes any missing demo file and returns all of them.
    @discardableResult
    static func ensure() -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, make) in catalog {
            let url = folder.appendingPathComponent("\(name).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                let mono = normalize(make())
                try? Bounce.writeWAV(RenderedAudio(left: mono, right: mono, sampleRate: rate), to: url)
            }
            urls.append(url)
        }
        return urls
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent("\(name).wav") }

    static var catalog: [(String, () -> [Float])] { [
        ("Drums A", { drums(variation: 0) }),
        ("Drums B", { drums(variation: 1) }),
        ("Drums C Fill", { drums(variation: 2) }),
        ("Bass 1", { bass(notes: [41.2, 41.2, 61.74, 55.0]) }),
        ("Bass 2", { bass(notes: [36.71, 36.71, 55.0, 49.0]) }),
        ("Pad Am", { pad(freqs: [110, 130.875, 164.875, 220]) }),
        ("Pad F", { pad(freqs: [87.375, 109.375, 131, 174.75]) }),
        ("Arp", { arp() }),
        ("Crash", { crash() }),
        ("Clap", { clap() }),
    ] }

    // MARK: Building blocks

    private struct Noise {
        var state: UInt32 = 12_345
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    private static func put(_ buffer: inout [Float], _ sound: [Float], at start: Int, gain: Float = 1) {
        for (i, v) in sound.enumerated() where start + i < buffer.count { buffer[start + i] += v * gain }
    }

    private static func normalize(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return x }
        let g = 0.45 / peak
        return x.map { $0 * g }
    }

    private static func kick() -> [Float] {
        var phase = 0.0
        return (0..<12_000).map { i in
            let t = Double(i) / rate
            phase += 2 * .pi * (42 + 120 * exp(-t * 30)) / rate
            return Float(sin(phase) * exp(-t * 8))
        }
    }

    private static func snare() -> [Float] {
        var noise = Noise()
        return (0..<9_600).map { i in
            let t = Double(i) / rate
            return Float(Double(noise.next()) * exp(-t * 22) * 0.55 + sin(2 * .pi * 190 * t) * exp(-t * 28) * 0.45)
        }
    }

    private static func hat(open: Bool) -> [Float] {
        var noise = Noise(state: open ? 7 : 99)
        var previous: Float = 0
        return (0..<(open ? 12_000 : 2_400)).map { i in
            let t = Double(i) / rate
            let n = noise.next()
            defer { previous = n }
            return (n - previous) * Float(exp(-t * (open ? 14 : 90))) * 0.35
        }
    }

    private static func drums(variation: Int) -> [Float] {
        var out = [Float](repeating: 0, count: bar)
        let kicks: [Int] = variation == 1 ? [0, 5, 6] : [0, 4]
        for k in kicks { put(&out, kick(), at: k * beat / 2) }
        for s in [2, 6] { put(&out, snare(), at: s * beat / 2) }
        if variation == 2 { for i in 0..<8 { put(&out, snare(), at: 2 * beat + i * beat / 4, gain: 0.45 + Float(i) * 0.07) } }
        for h in 0..<8 { put(&out, hat(open: variation == 1 && h == 7), at: h * beat / 2, gain: h % 2 == 0 ? 1 : 0.6) }
        return out
    }

    private static func bass(notes: [Double]) -> [Float] {
        var out = [Float](repeating: 0, count: 2 * bar)
        for (n, f) in notes.enumerated() {
            let length = beat * 2
            let start = n * length
            let sound: [Float] = (0..<length).map { i in
                let t = Double(i) / rate
                let env = min(1, t / 0.004) * exp(-t * 2.4)
                return Float((sin(2 * .pi * f * t) + 0.45 * sin(4 * .pi * f * t) + 0.2 * sin(6 * .pi * f * t)) * env)
            }
            put(&out, sound, at: start)
        }
        return out
    }

    private static func pad(freqs: [Double]) -> [Float] {
        let length = 4 * bar // 8 s: every frequency here makes a whole number of cycles
        return (0..<length).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for f in freqs { v += sin(2 * .pi * f * t) + 0.6 * sin(2 * .pi * (f + 0.125) * t) }
            return Float(v * (0.75 + 0.25 * sin(2 * .pi * 0.25 * t)) * 0.12)
        }
    }

    private static func arp() -> [Float] {
        var out = [Float](repeating: 0, count: 2 * bar)
        let pattern: [Double] = [220, 261.63, 329.63, 440, 329.63, 261.63, 196, 246.94, 293.66, 392, 293.66, 246.94, 220, 261.63, 329.63, 523.25]
        let step = beat / 4
        for i in 0..<32 {
            let f = pattern[i % pattern.count]
            let sound: [Float] = (0..<9_000).map { k in
                let t = Double(k) / rate
                return Float((sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)) * exp(-t * 16) * min(1, t / 0.002))
            }
            put(&out, sound, at: i * step, gain: 0.5)
        }
        return out
    }

    private static func crash() -> [Float] {
        var noise = Noise(state: 4_242)
        var previous: Float = 0
        return (0..<(3 * 48_000)).map { i in
            let t = Double(i) / rate
            let n = noise.next()
            defer { previous = n }
            return (n - previous) * Float(exp(-t * 2.2)) * 0.5
        }
    }

    private static func clap() -> [Float] {
        var noise = Noise(state: 31)
        var out = [Float](repeating: 0, count: 14_000)
        for burst in 0..<3 {
            let sound: [Float] = (0..<2_400).map { i in Float(Double(noise.next()) * exp(-Double(i) / rate * 70)) * 0.5 }
            put(&out, sound, at: burst * 700)
        }
        let tail: [Float] = (0..<10_000).map { i in Float(Double(noise.next()) * exp(-Double(i) / rate * 22)) * 0.35 }
        put(&out, tail, at: 2_100)
        return out
    }
}
