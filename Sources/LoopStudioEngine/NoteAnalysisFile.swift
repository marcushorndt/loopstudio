import Foundation

/// A note analysis as a file, so a project that opens again shows its notes at once instead of finding them
/// again. The format is little-endian binary: a header, then per note its key, span, pitch and per-frame
/// arrays. `version` changes whenever the analysis changes, so an old file is found again, not reused.
extension NoteAnalysis {
    /// Bump when `analyze` gives other notes for the same file.
    public static let fileVersion: UInt32 = 1
    private static let magic: UInt32 = 0x414E_534C // "LSNA"

    public func fileData() -> Data {
        var w = Writer()
        w.u32(Self.magic); w.u32(Self.fileVersion)
        w.f64(sampleRate); w.i64(size); w.i64(hop); w.i64(harmonics); w.i64(channels); w.i64(frames)
        w.i64(notes.count)
        for n in notes {
            w.string(n.key)
            w.i64(n.startFrame); w.i64(n.endFrame); w.f64(n.pitch)
            w.floats(n.f0); w.floats(n.level); w.floats(n.freqs)
            w.i64(n.amps.count)
            for a in n.amps { w.floats(a) }
        }
        return w.data
    }

    /// The analysis from `fileData()`, or nil for another version, another layout or a broken file.
    public static func read(_ data: Data) -> NoteAnalysis? {
        var r = Reader(data: data)
        guard r.u32() == magic, r.u32() == fileVersion,
              let rate = r.f64(), let size = r.i64(), let hop = r.i64(), let h = r.i64(), let channels = r.i64(),
              let frames = r.i64(), let count = r.i64(), h == 24, count >= 0, count < 1_000_000 else { return nil }
        var notes: [DetectedNote] = []
        notes.reserveCapacity(count)
        for _ in 0..<count {
            guard let key = r.string(), let start = r.i64(), let end = r.i64(), let pitch = r.f64(), end >= start,
                  let f0 = r.floats(), let level = r.floats(), let freqs = r.floats(), let ampCount = r.i64(),
                  ampCount >= 0, ampCount <= 16 else { return nil }
            let length = end - start + 1
            var amps: [[Float]] = []
            for _ in 0..<ampCount {
                guard let a = r.floats(), a.count == length * h else { return nil }
                amps.append(a)
            }
            guard f0.count == length, level.count == length, freqs.count == length * h else { return nil }
            notes.append(DetectedNote(key: key, startFrame: start, endFrame: end, pitch: pitch, f0: f0, level: level,
                                      freqs: freqs, amps: amps))
        }
        guard r.atEnd else { return nil }
        return NoteAnalysis(stored: rate, size: size, hop: hop, notes: notes, channels: channels, frames: frames)
    }
}

private struct Writer {
    var data = Data()
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int) { withUnsafeBytes(of: Int64(v).littleEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    mutating func string(_ s: String) { let b = Array(s.utf8); i64(b.count); data.append(contentsOf: b) }
    mutating func floats(_ a: [Float]) {
        i64(a.count)
        for v in a { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    }
}

private struct Reader {
    let data: Data
    var at = 0
    init(data: Data) { self.data = data }
    var atEnd: Bool { at == data.count }

    private mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, at + n <= data.count else { return nil }
        defer { at += n }
        return data.subdata(in: data.startIndex + at..<data.startIndex + at + n)
    }
    private mutating func u64() -> UInt64? {
        bytes(8).map { b in b.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
    }
    mutating func u32() -> UInt32? {
        bytes(4).map { b in b.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
    }
    mutating func i64() -> Int? { u64().map { Int(Int64(bitPattern: $0)) } }
    mutating func f64() -> Double? { u64().map(Double.init(bitPattern:)) }
    mutating func string() -> String? {
        guard let n = i64(), n < 1024, let b = bytes(n) else { return nil }
        return String(data: b, encoding: .utf8)
    }
    mutating func floats() -> [Float]? {
        guard let n = i64(), n >= 0, n < 100_000_000, let b = bytes(n * 4) else { return nil }
        return b.withUnsafeBytes { raw in
            (0..<n).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}
