import Accelerate
import AVFoundation
import Foundation
import LoopStudioCore

/// A note the analysis found in a file: where it starts and ends, its pitch over time and its partials.
public struct DetectedNote: Sendable, Hashable {
    /// "<first frame>-<MIDI note>": the same file gives the same keys, so a `NoteChange` finds its note again.
    public let key: String
    /// Analysis frames, inclusive.
    public let startFrame: Int
    public let endFrame: Int
    /// The note's pitch as a MIDI number with cents (the median over its frames).
    public let pitch: Double
    /// The fundamental per frame, in Hz.
    public let f0: [Float]
    /// The loudness per frame (the sum of the partials' amplitudes), for the blob.
    public let level: [Float]
    /// Per frame and partial (`(frame - startFrame) * harmonics + h`): the partial's frequency, and its
    /// amplitude per channel.
    let freqs: [Float]
    let amps: [[Float]]

    public var frames: Int { endFrame - startFrame + 1 }
}

/// The notes of a file, after Melodyne's polyphonic mode, and the render of a file with notes changed.
///
/// Analysis: a short-time spectrum (4096 frames, a hop of 512 at 48 kHz) with its peaks. In each frame the
/// strongest harmonic series is found among the peaks: a candidate is a peak between 41 Hz and 2.1 kHz, its
/// salience the weighted sum of the peaks at its multiples (Klapuri's weights, a 3 % window). The winner's
/// partials are then taken out of the peaks (each by the smaller of its own size and its neighbours', so a
/// partial two notes share keeps the other note's part), and the search goes on for up to six notes while a
/// series is at least a fifth as strong as the first. Frames link into notes by pitch (within 0.6 semitones,
/// gaps of five frames), a note splits where its level jumps after a dip or its pitch leaves its line, and a
/// note shorter than 60 ms goes. Each note's partials are then measured again on the full spectrum.
///
/// Render: the edited notes are cut out of the file (their partials' bins masked out of a short-time
/// spectrum, the rest kept), and built again from their partials by additive synthesis with the new pitch,
/// time, length and level. With formants kept, a partial takes the level the original spectrum envelope had
/// at its new frequency. Notes that did not change are never touched, so they sound as recorded.
public final class NoteAnalysis: @unchecked Sendable {
    public let sampleRate: Double
    public let size: Int
    public let hop: Int
    public let harmonics = 24
    public let notes: [DetectedNote]
    public let channels: Int
    public let frames: Int

    /// The time of a frame's centre. Frame t's window starts half a window before `t * hop`.
    public func seconds(frame: Double) -> Double { frame * Double(hop) / sampleRate }

    /// An analysis read back from its file (`NoteAnalysisFile.swift`).
    convenience init(stored sampleRate: Double, size: Int, hop: Int, notes: [DetectedNote], channels: Int, frames: Int) {
        self.init(sampleRate: sampleRate, size: size, hop: hop, notes: notes, channels: channels, frames: frames)
    }

    private init(sampleRate: Double, size: Int, hop: Int, notes: [DetectedNote], channels: Int, frames: Int) {
        self.sampleRate = sampleRate
        self.size = size
        self.hop = hop
        self.notes = notes
        self.channels = channels
        self.frames = frames
    }

    // MARK: Spectrum

    struct Peak { var freq: Float; var amp: Float }

    /// A real FFT of `size` points with a Hann window. `magnitudes` gives sine amplitudes per bin.
    final class Spectrum {
        let size: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        var real: [Float]
        var imag: [Float]
        private var frame: [Float]

        init(size: Int) {
            self.size = size
            log2n = vDSP_Length(log2(Double(size)).rounded())
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
            real = [Float](repeating: 0, count: size / 2)
            imag = [Float](repeating: 0, count: size / 2)
            frame = [Float](repeating: 0, count: size)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// The spectrum of `count` samples from `source` at `start` (zero outside), windowed.
        func forward(_ source: UnsafePointer<Float>, count: Int, start: Int) {
            for i in 0..<size {
                let j = start + i
                frame[i] = (j >= 0 && j < count ? source[j] : 0) * window[i]
            }
            real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            } }
        }

        /// Back to time, windowed again, into `out` (`size` samples). The forward and back pass scale by 2N.
        func inverse(into out: inout [Float]) {
            real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2)) }
                }
            } }
            let scale = 1 / Float(2 * size)
            for i in 0..<size { out[i] *= window[i] * scale }
        }

        /// Sine amplitude per bin (bin 0 and the Nyquist bin left out).
        func magnitudes(into m: inout [Float]) {
            // zrip gives twice the DFT, and a sine of amplitude A peaks at A * N / 4 through a Hann window:
            // A * N / 2 in all, so 2 / N gives A back.
            let scale = 2 / Float(size)
            m[0] = 0
            for k in 1..<(size / 2) { m[k] = sqrtf(real[k] * real[k] + imag[k] * imag[k]) * scale }
        }
    }

    /// The peaks of one magnitude spectrum, with the frequency and amplitude refined between bins.
    static func peaks(_ m: [Float], sampleRate: Double, size: Int, floor: Float) -> [Peak] {
        var out: [Peak] = []
        let binHz = Float(sampleRate) / Float(size)
        var around = [Float](repeating: 0, count: 41)
        for k in 2..<(m.count - 1) where m[k] > floor && m[k] > m[k - 1] && m[k] >= m[k + 1] {
            // A partial stands out of the spectrum around it; a peak of noise does not. 12 dB over the median
            // of the 40 bins around it.
            let lo = max(1, k - 20), hi = min(m.count - 1, k + 20)
            let n = hi - lo + 1
            for j in 0..<n { around[j] = m[lo + j] }
            around[0..<n].sort()
            guard m[k] > around[n / 2] * 4 else { continue }
            let a = 20 * log10f(max(m[k - 1], 1e-9)), b = 20 * log10f(m[k]), c = 20 * log10f(max(m[k + 1], 1e-9))
            let d = a - 2 * b + c
            let p = d == 0 ? 0 : 0.5 * (a - c) / d
            let db = b - 0.25 * (a - c) * p
            out.append(Peak(freq: (Float(k) + p) * binHz, amp: powf(10, db / 20)))
        }
        return out
    }

    /// The peak nearest `freq` within 3 %, by index into `peaks` (sorted by frequency).
    static func nearest(_ peaks: [Peak], _ freq: Float) -> Int? {
        var lo = 0, hi = peaks.count
        while lo < hi { let mid = (lo + hi) / 2; if peaks[mid].freq < freq { lo = mid + 1 } else { hi = mid } }
        var best: Int?
        for i in [lo - 1, lo] where i >= 0 && i < peaks.count {
            let d = abs(peaks[i].freq - freq)
            if d <= freq * 0.03, best.map({ d < abs(peaks[$0].freq - freq) }) ?? true { best = i }
        }
        return best
    }

    // MARK: Analysis

    /// Finds the notes of a file. `progress` gets 0...1 now and then.
    public static func analyze(_ pcm: PCMBuffer, progress: ((Double) -> Void)? = nil) -> NoteAnalysis {
        let rate = pcm.sampleRate
        let size = rate > 60_000 ? 8_192 : 4_096
        let hop = size / 8
        let count = pcm.frames
        let frames = max(1, (count + size / 2) / hop)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<pcm.channels { let ch = pcm.channel(c); for i in 0..<count { mono[i] += ch[i] / Float(pcm.channels) } }
        let spectrum = Spectrum(size: size), long = Spectrum(size: size * 2)
        var mags = [Float](repeating: 0, count: size / 2), longMags = [Float](repeating: 0, count: size)
        /// The peaks of frame t: below 700 Hz from a window twice as long (two low notes a semitone apart stay
        /// two peaks), above it from the short one (attacks stay sharp).
        func framePeaks(_ src: UnsafePointer<Float>, _ t: Int, floor: Float?) -> [Peak] {
            spectrum.forward(src, count: count, start: t * hop - size / 2)
            spectrum.magnitudes(into: &mags)
            long.forward(src, count: count, start: t * hop - size)
            long.magnitudes(into: &longMags)
            let top = max(mags.max() ?? 0, longMags.max() ?? 0)
            let f = floor ?? max(0.0005, top * 0.003)
            let low = Self.peaks(longMags, sampleRate: rate, size: size * 2, floor: f).filter { $0.freq < 700 }
            let short = Self.peaks(mags, sampleRate: rate, size: size, floor: f)
            lastShort = short
            return low + short.filter { $0.freq >= 700 }
        }
        var lastShort: [Peak] = []
        /// The short window's peaks per frame: the level for the split of a note keeps the attacks sharp.
        var shortPeaks: [[Peak]] = []
        shortPeaks.reserveCapacity(frames)
        var allPeaks: [[Peak]] = []
        allPeaks.reserveCapacity(frames)
        // Per frame: the series found, as (fundamental in Hz, strength).
        var found: [[(f0: Float, strength: Float)]] = []
        found.reserveCapacity(frames)
        let H = 24
        mono.withUnsafeBufferPointer { src in
            for t in 0..<frames {
                let peaks = framePeaks(src.baseAddress!, t, floor: nil)
                allPeaks.append(peaks)
                shortPeaks.append(lastShort)
                found.append(series(in: peaks, harmonics: H, nyquist: Float(rate / 2)))
                if t % 256 == 0 { progress?(Double(t) / Double(frames) * 0.8) }
            }
        }
        // A note splits on the level of its partials in the short window, where a short gap still shows.
        let linked = link(found)
        let middles: [(start: Int, end: Int, f0: Float)] = linked.map { t in
            let sorted = t.f0.sorted()
            return (t.start, t.start + t.f0.count - 1, sorted[sorted.count / 2])
        }
        let tracks = linked.enumerated().flatMap { index, track -> [Track] in
            let me = middles[index]
            // Each partial is read where it stands alone. A partial with another note's partial inside the short
            // window's main lobe (two bins) beats there, and a beat is no attack: it is read in the long window
            // (the analysis peaks, long below 700 Hz). A partial that shares even the long window's lobe with
            // another note leaves out: that note's level would hide a gap. Of the rest, the partials the note
            // has in at least half of its frames count.
            let others = middles.enumerated().filter { $0.offset != index && $0.element.start <= me.end && $0.element.end >= me.start }.map(\.element.f0)
            func near(_ f: Float, within: Float) -> Bool {
                others.contains { o in (1...24).contains { k in abs(o * Float(k) - f) < within } }
            }
            let shortLobe = 2 * Float(rate) / Float(size), longLobe = shortLobe / 2
            var reads: [(h: Int, source: [[Peak]])] = []
            for h in 1...8 {
                let f = me.f0 * Float(h)
                guard f < Float(rate / 2) * 0.95 else { break }
                let source: [[Peak]]
                if !near(f, within: max(shortLobe, f * 0.012)) { source = shortPeaks }
                else if f < 700 && !near(f, within: max(longLobe, f * 0.012)) { source = allPeaks }
                else { continue }
                var hits = 0
                for i in 0..<track.f0.count where nearest(source[track.start + i], track.f0[i] * Float(h)) != nil { hits += 1 }
                if hits * 2 >= track.f0.count { reads.append((h, source)) }
            }
            if reads.isEmpty { reads = [(1, allPeaks)] }
            var levels = [Float](repeating: 0, count: track.f0.count)
            for i in 0..<track.f0.count {
                // The strongest of those partials: in a gap all of them fall.
                for (h, source) in reads {
                    let list = source[track.start + i]
                    levels[i] = max(levels[i], nearest(list, track.f0[i] * Float(h)).map { list[$0].amp } ?? 0)
                }
            }
            // A median over five frames against what flickers. A gap of 60 ms and more stays.
            var t = track
            t.strength = levels.indices.map { i in
                let w = levels[max(0, i - 2)...min(levels.count - 1, i + 2)].sorted()
                return w[w.count / 2]
            }
            return split(t)
        }
        // Each note's partials, measured again on the full peaks of its frames.
        var notes: [DetectedNote] = []
        var channelPeaks: [[[Peak]]] = []
        if pcm.channels > 1 {
            // Per channel amplitudes: the same analysis on each channel's own spectrum.
            for c in 0..<pcm.channels {
                var list: [[Peak]] = []
                list.reserveCapacity(frames)
                let ch = pcm.channel(c)
                for t in 0..<frames { list.append(framePeaks(ch, t, floor: 0.0001)) }
                channelPeaks.append(list)
                progress?(0.8 + 0.2 * Double(c + 1) / Double(pcm.channels))
            }
        }
        for track in tracks {
            let n = track.f0.count
            var freqs = [Float](repeating: 0, count: n * H)
            var amps = [[Float]](repeating: [Float](repeating: 0, count: n * H), count: pcm.channels)
            var level = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = track.start + i, f0 = track.f0[i]
                for h in 0..<H {
                    let target = f0 * Float(h + 1)
                    guard target < Float(rate / 2) * 0.95 else { break }
                    let peaks = allPeaks[t]
                    if let k = nearest(peaks, target) {
                        freqs[i * H + h] = peaks[k].freq
                        level[i] += peaks[k].amp
                        if pcm.channels == 1 { amps[0][i * H + h] = peaks[k].amp }
                    } else {
                        freqs[i * H + h] = target
                    }
                    if pcm.channels > 1 {
                        for c in 0..<pcm.channels {
                            let list = channelPeaks[c][t]
                            if let k = nearest(list, freqs[i * H + h]) { amps[c][i * H + h] = list[k].amp }
                        }
                    }
                }
            }
            let sorted = track.f0.map { 69 + 12 * log2(Double($0) / 440) }.sorted()
            let pitch = sorted[sorted.count / 2]
            notes.append(DetectedNote(key: "\(track.start)-\(Int(pitch.rounded()))", startFrame: track.start, endFrame: track.start + n - 1,
                                      pitch: pitch, f0: track.f0, level: level, freqs: freqs, amps: amps))
        }
        notes.sort { ($0.startFrame, $0.pitch) < ($1.startFrame, $1.pitch) }
        progress?(1)
        return NoteAnalysis(sampleRate: rate, size: size, hop: hop, notes: notes, channels: pcm.channels, frames: frames)
    }

    /// The harmonic series in one frame's peaks, strongest first, up to six.
    static func series(in source: [Peak], harmonics H: Int, nyquist: Float) -> [(f0: Float, strength: Float)] {
        var peaks = source
        var out: [(Float, Float)] = []
        var first: Float = 0
        for _ in 0..<6 {
            var best: (f0: Float, salience: Float, members: [(Int, Int)])?
            // A note found once is not found again from what is left of its partials.
            for (i, p) in peaks.enumerated() where p.freq >= 41 && p.freq <= 2_100 && p.amp > 0
                && !out.contains(where: { abs(12 * log2f(p.freq / $0.0)) < 0.5 }) {
                var salience: Float = 0
                var members: [(Int, Int)] = []
                var hits = 0
                for h in 1...H {
                    let target = p.freq * Float(h)
                    if target > nyquist * 0.95 { break }
                    guard let k = h == 1 ? i : nearest(peaks, target), peaks[k].amp > 0 else { continue }
                    // Klapuri's weight: low partials of low notes count most.
                    let w = (p.freq + 27) / (target + 320)
                    salience += w * peaks[k].amp
                    members.append((h, k))
                    hits += 1
                }
                // A single peak is no series: at least two partials, the fundamental among them.
                guard hits >= 2 else { continue }
                if best == nil || salience > best!.salience { best = (p.freq, salience, members) }
            }
            guard let b = best else { break }
            if out.isEmpty { first = b.salience } else if b.salience < first * 0.2 { break }
            // The fundamental, refined from the partials: their frequency over their number, by amplitude.
            var sum: Float = 0, weight: Float = 0
            for (h, k) in b.members where h <= 8 { sum += peaks[k].freq / Float(h) * peaks[k].amp; weight += peaks[k].amp }
            out.append((weight > 0 ? sum / weight : b.f0, b.salience))
            // Take the series out: each partial by the smaller of its own size and its neighbours' mean, so a
            // partial shared with another note keeps that note's part.
            let sizes = b.members.map { peaks[$0.1].amp }
            for (j, member) in b.members.enumerated() {
                let left = j > 0 ? sizes[j - 1] : sizes[j], right = j + 1 < sizes.count ? sizes[j + 1] : sizes[j]
                let estimate = min(sizes[j], max((left + right) / 2, sizes[j] * 0.5))
                peaks[member.1].amp = max(0, peaks[member.1].amp - estimate * 1.0001)
            }
        }
        // A strong peak left over that is no partial of a note found: a note of one partial (a sine, a soft
        // flute). Half of it must be left after the series took their parts, and it must be a quarter of the
        // strongest peak.
        let strongest = source.map(\.amp).max() ?? 0
        for (i, p) in peaks.enumerated() where out.count < 6 && p.freq >= 41 && p.freq <= 2_100 {
            guard p.amp > source[i].amp * 0.5, p.amp > strongest * 0.25 else { continue }
            let partial = out.contains { f in (1...8).contains { h in abs(p.freq - f.0 * Float(h)) < f.0 * Float(h) * 0.03 } }
            guard !partial else { continue }
            out.append((p.freq, p.amp * (p.freq + 27) / (p.freq + 320)))
        }
        return out
    }

    struct Track { var start: Int; var f0: [Float]; var strength: [Float]; var lastSeen: Int }

    /// Links the series of the frames into notes.
    static func link(_ found: [[(f0: Float, strength: Float)]]) -> [Track] {
        var open: [Track] = []
        var done: [Track] = []
        func midi(_ f: Float) -> Float { 69 + 12 * log2f(f / 440) }
        func close(_ track: Track) {
            // The frames after its last sighting are not the note.
            var t = track
            let keep = t.lastSeen - t.start + 1
            t.f0 = Array(t.f0.prefix(keep)); t.strength = Array(t.strength.prefix(keep))
            if t.f0.count >= 6 { done.append(t) }
        }
        for (frame, list) in found.enumerated() {
            var taken = Set<Int>()
            for s in list.sorted(by: { $0.strength > $1.strength }) {
                let m = midi(s.f0)
                var bestIndex: Int?
                var bestDistance: Float = 0.6
                for (i, track) in open.enumerated() where !taken.contains(i) {
                    let d = abs(midi(track.f0[track.lastSeen - track.start]) - m)
                    if d < bestDistance { bestDistance = d; bestIndex = i }
                }
                if let i = bestIndex {
                    // Fill a gap with the last pitch, so the frames stay one per index.
                    while open[i].start + open[i].f0.count < frame {
                        open[i].f0.append(open[i].f0.last!); open[i].strength.append(0)
                    }
                    open[i].f0.append(s.f0); open[i].strength.append(s.strength); open[i].lastSeen = frame
                    taken.insert(i)
                } else {
                    open.append(Track(start: frame, f0: [s.f0], strength: [s.strength], lastSeen: frame))
                    taken.insert(open.count - 1)
                }
            }
            // A note not seen for more than five frames (53 ms) has ended. A shorter gap is a note that the
            // search lost for a moment; a real new attack on the same pitch splits it later.
            var still: [Track] = []
            for track in open { if frame - track.lastSeen > 5 { close(track) } else { still.append(track) } }
            open = still
        }
        for track in open { close(track) }
        return done.sorted { $0.start < $1.start }
    }

    /// A track splits where its level rises steeply after a dip (a new attack on the same pitch), or where its
    /// pitch leaves the line of the last frames by more than 0.7 semitones (the next note of a legato line).
    static func split(_ track: Track) -> [Track] {
        var parts: [Track] = []
        var start = 0
        func midi(_ f: Float) -> Float { 69 + 12 * log2f(f / 440) }
        var low = track.strength[0], peak = track.strength[0]
        for i in 1..<track.f0.count {
            let here = i - start
            low = min(low, track.strength[i - 1])
            peak = max(peak, track.strength[i - 1])
            // A new attack: the level fell to under a quarter of the note's peak and rises steeply again.
            // A partial that beats with another note's moves less than that.
            // The new attack must reach a third of the old peak within three frames; a rest of the old note
            // that flickers as it dies out is no new note.
            let next = track.strength[i..<min(track.strength.count, i + 4)].max() ?? 0
            let attack = here >= 6 && low < peak * 0.25 && track.strength[i] > max(low, peak * 0.05) * 3
                && track.strength[i] > track.strength[i - 1] * 1.5 && next > peak * 0.33
            let recent = track.f0[max(start, i - 5)..<i].map(midi).sorted()
            let line = recent[recent.count / 2]
            let leaves = here >= 6 && abs(midi(track.f0[i]) - line) > 0.7
                && (i + 2 < track.f0.count ? abs(midi(track.f0[i + 2]) - line) > 0.7 : true)
            if attack || leaves {
                parts.append(Track(start: track.start + start, f0: Array(track.f0[start..<i]), strength: Array(track.strength[start..<i]), lastSeen: 0))
                start = i
                low = track.strength[i]
                peak = track.strength[i]
            }
        }
        parts.append(Track(start: track.start + start, f0: Array(track.f0[start...]), strength: Array(track.strength[start...]), lastSeen: 0))
        return parts.filter { $0.f0.count >= 6 }
    }

    // MARK: Render

    /// The part of each partial that belongs to the note, per channel, and the share of the measured peak it
    /// is. Where another note that sounds at the same time has a partial close by, the peak holds both, and
    /// the note's part is estimated from its neighbour partials (a spectrum is smooth along its harmonics).
    func ownParts(_ note: DetectedNote, channel c: Int) -> (amps: [Float], share: [Float]) {
        let H = harmonics
        let measured = note.amps[min(c, note.amps.count - 1)]
        var amps = measured
        var share = [Float](repeating: 1, count: measured.count)
        let others = notes.filter { $0.key != note.key && $0.startFrame <= note.endFrame && $0.endFrame >= note.startFrame }
        guard !others.isEmpty else { return (amps, share) }
        let binHz = Float(sampleRate) / Float(size * 2)
        for i in 0..<note.frames {
            let t = note.startFrame + i
            let near: [Float] = others.flatMap { o -> [Float] in
                guard t >= o.startFrame, t <= o.endFrame else { return [] }
                let j = t - o.startFrame
                return (0..<H).compactMap { h in o.amps[0][j * H + h] > 0 ? o.freqs[j * H + h] : nil }
            }
            guard !near.isEmpty else { continue }
            var isShared = [Bool](repeating: false, count: H)
            for h in 0..<H {
                let f = note.freqs[i * H + h]
                isShared[h] = measured[i * H + h] > 0 && near.contains { abs($0 - f) < max(2 * binHz, f * 0.012) }
            }
            for h in 0..<H where isShared[h] {
                // The nearest partials below and above that are the note's alone.
                var lo = h - 1, hi = h + 1
                while lo >= 0 && (isShared[lo] || measured[i * H + lo] <= 0) { lo -= 1 }
                while hi < H && (isShared[hi] || measured[i * H + hi] <= 0) { hi += 1 }
                let a = measured[i * H + h]
                let estimate: Float
                switch (lo >= 0, hi < H) {
                case (true, true):
                    let x = Float(h - lo) / Float(hi - lo)
                    estimate = expf(logf(measured[i * H + lo]) * (1 - x) + logf(measured[i * H + hi]) * x)
                case (true, false): estimate = measured[i * H + lo] * Float(lo + 1) / Float(h + 1)
                case (false, true): estimate = measured[i * H + hi]
                default: estimate = a * 0.5
                }
                amps[i * H + h] = min(a, estimate)
                share[i * H + h] = a > 0 ? min(1, estimate / a) : 0
            }
        }
        return (amps, share)
    }

    /// The file with the edit's changes. `nil` when nothing changes.
    public func render(_ pcm: PCMBuffer, edit: NoteEdit) -> PCMBuffer? {
        let edited: [(DetectedNote, NoteChange)] = notes.compactMap { n in edit.change(n.key).map { (n, $0) } }
        guard !edited.isEmpty else { return nil }
        let count = pcm.frames
        let out = PCMBuffer(channels: pcm.channels, frames: count, sampleRate: pcm.sampleRate)
        for c in 0..<pcm.channels {
            let src = pcm.channel(c), dst = out.mutableChannel(c)
            dst.update(from: src, count: count)
            let parts = edited.map { ownParts($0.0, channel: c) }
            // Cut the edited notes out: their part of the spectrum, frame by frame, taken off the file. Below
            // 700 Hz through a window twice as long, so two low notes a semitone apart stay apart; above it
            // through the short one, so an attack stays sharp.
            for (n, (note, change)) in edited.enumerated() {
            var cut = [Float](repeating: 0, count: count)
            for (window, band) in [(size * 2, Float(0)..<Float(700)), (size, Float(700)..<Float.greatestFiniteMagnitude)] {
                let spectrum = Spectrum(size: window)
                let step = window / 4
                let binHz = Float(sampleRate) / Float(window)
                var block = [Float](repeating: 0, count: window)
                var mask = [Float](repeating: 0, count: window / 2)
                var s = -window
                while s < count {
                    for k in 0..<mask.count { mask[k] = 0 }
                    var any = false
                    // The analysis frame at this window's centre.
                    let t = Double(s + window / 2) / Double(hop)
                    do {
                        let local = t - Double(note.startFrame)
                        guard local >= -2, local <= Double(note.frames + 1) else { s += step; continue }
                        let i = min(max(Int(local.rounded()), 0), note.frames - 1)
                        for h in 0..<harmonics {
                            let f = note.freqs[i * harmonics + h]
                            let share = parts[n].share[i * harmonics + h]
                            guard band.contains(f), parts[n].amps[i * harmonics + h] > 0, share > 0 else { continue }
                            let centre = f / binHz
                            let lo = max(1, Int((centre - 2).rounded(.down))), hi = min(window / 2 - 1, Int((centre + 2).rounded(.up)))
                            guard lo <= hi else { continue }
                            for k in lo...hi { mask[k] = max(mask[k], share); any = true }
                        }
                    }
                    if any {
                        spectrum.forward(src, count: count, start: s)
                        for k in 0..<(window / 2) { spectrum.real[k] *= mask[k]; spectrum.imag[k] *= mask[k] }
                        spectrum.imag[0] = 0 // the Nyquist bin
                        spectrum.inverse(into: &block)
                        // Overlap-add of a Hann window squared at a hop of a quarter: 1.5.
                        for i in 0..<window {
                            let j = s + i
                            if j >= 0 && j < count { cut[j] += block[i] / 1.5 }
                        }
                    }
                    s += step
                }
            }
            // A note that keeps its pitch and its time only changes its level: its own part, scaled, keeps
            // every detail of the recording. Any other note is built again from its partials.
            let keeps = change.pitch == 0 && change.shift == 0 && change.stretch == 1
            if keeps {
                let gain = change.muted ? 0 : Float(pow(10, change.gainDb / 20))
                for i in 0..<count { dst[i] -= cut[i] * (1 - gain) }
            } else {
                for i in 0..<count { dst[i] -= cut[i] }
                if !change.muted {
                    synthesize(note, amps: parts[n].amps, change: change, keepFormants: edit.keepFormants, into: dst, count: count)
                }
            }
            }
        }
        return out
    }

    /// Adds one note, changed, to `dst`: every partial a sine whose frequency and amplitude follow the
    /// measured frames, read at the stretched time and shifted.
    private func synthesize(_ note: DetectedNote, amps: [Float], change: NoteChange, keepFormants: Bool,
                            into dst: UnsafeMutablePointer<Float>, count: Int) {
        let rate = Float(sampleRate)
        let ratio = Float(pow(2, change.pitch / 12))
        let gain = Float(pow(10, change.gainDb / 20))
        let stretch = max(0.1, change.stretch)
        let H = harmonics
        let n = note.frames
        // Frame i of the note sounds at its centre; the note is stretched from its first frame's centre on.
        let firstCentre = Double(note.startFrame * hop)
        let begin = firstCentre + change.shift * sampleRate - Double(hop)
        let end = firstCentre + change.shift * sampleRate + Double(n) * Double(hop) * stretch
        let lo = max(0, Int(begin)), hi = min(count, Int(end.rounded(.up)))
        guard lo < hi else { return }
        // The level a partial gets at frequency f in frame i: with formants kept, the envelope of the
        // original partials of that frame at f.
        func envelope(_ i: Int, _ f: Float) -> Float {
            var below: (Float, Float)?, above: (Float, Float)?
            for h in 0..<H {
                let fh = note.freqs[i * H + h], a = amps[i * H + h]
                guard fh > 0, a > 0 else { continue } // a partial the note lacks is no point of the envelope
                if fh <= f { below = (fh, a) } else if above == nil { above = (fh, a) }
            }
            switch (below, above) {
            case let (b?, a?):
                let x = (f - b.0) / max(1, a.0 - b.0)
                let lb = logf(max(b.1, 1e-6)), la = logf(max(a.1, 1e-6))
                return expf(lb + (la - lb) * x)
            case let (b?, nil): return b.1 * expf(-(f - b.0) / max(200, b.0 * 0.25))
            case let (nil, a?): return a.1
            default: return 0
            }
        }
        // Amplitudes per partial and frame, changed once: the formant envelope is costly per sample.
        var table = [Float](repeating: 0, count: n * H)
        for i in 0..<n {
            for h in 0..<H {
                let f = note.freqs[i * H + h]
                guard f > 0 else { continue }
                let a = keepFormants && ratio != 1 ? envelope(i, f * ratio) : amps[i * H + h]
                // Partials that would pass the Nyquist frequency stay out.
                table[i * H + h] = f * ratio < rate * 0.48 ? a * gain : 0
            }
        }
        for h in 0..<H {
            var phase: Float = 0
            var any = false
            for i in 0..<n where table[i * H + h] > 0 { any = true; break }
            guard any else { continue }
            for j in lo..<hi {
                // Where in the note this sample is, in frames: -1 before the first frame fades in from 0.
                let pos = (Double(j) - change.shift * sampleRate - firstCentre) / stretch / Double(hop)
                let i0 = Int(pos.rounded(.down)), frac = Float(pos - Double(i0))
                func at(_ i: Int) -> (Float, Float) {
                    guard i >= 0, i < n else {
                        let k = min(max(i, 0), n - 1)
                        return (note.freqs[k * H + h] * ratio, 0)
                    }
                    return (note.freqs[i * H + h] * ratio, table[i * H + h])
                }
                let (f0, a0) = at(i0), (f1, a1) = at(i0 + 1)
                let f = f0 + (f1 - f0) * frac, a = a0 + (a1 - a0) * frac
                phase += 2 * .pi * f / rate
                if phase > 2 * .pi { phase -= 2 * .pi }
                dst[j] += a * sinf(phase)
            }
        }
    }
}

public extension PCMBuffer {
    /// Writes the buffer as a 32-bit float CAF file.
    func write(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var at = 0
        while at < frames {
            let n = min(chunk, frames - at)
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels { buffer.floatChannelData![c].update(from: channel(c) + at, count: n) }
            try file.write(from: buffer)
            at += n
        }
    }
}
