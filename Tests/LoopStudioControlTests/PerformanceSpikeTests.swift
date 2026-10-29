import Accelerate
import AVFoundation
import Foundation
import Testing
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject
@testable import LoopStudioControl

/// The two performance risks of the plan (architecture.md, section 17), measured. `LOOPSTUDIO_PERF=1` runs
/// them; they print their numbers. The thousand-clip project is also written to the projects folder, as
/// "Perf 1000 Clips", so the app can open it and the timeline can be looked at by hand.
private let rate = 48_000.0

private func resident() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return r == KERN_SUCCESS ? Int(info.resident_size) : 0
}

private func writeWAV(seconds: Double, to url: URL, _ signal: (Int) -> Float) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = 1 << 16
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
    var written = 0
    let total = Int(seconds * rate)
    while written < total {
        let n = min(chunk, total - written)
        for i in 0..<n {
            let v = signal(written + i)
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        buffer.frameLength = AVAudioFrameCount(n)
        try file.write(from: buffer)
        written += n
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPSTUDIO_PERF"] == "1"))
func aThousandClipsRenderFasterThanRealtime() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loopstudio-perf", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // Two loops: a bass-like tone and a click pattern, 2 s each (one bar at 120 BPM).
    let toneURL = tmp.appendingPathComponent("perf-tone.wav"), clickURL = tmp.appendingPathComponent("perf-click.wav")
    try writeWAV(seconds: 2, to: toneURL) { 0.3 * sinf(2 * .pi * 110 * Float($0) / Float(rate)) * (1 - Float($0 % 24_000) / 24_000) }
    try writeWAV(seconds: 2, to: clickURL) { ($0 % 12_000) < 200 ? 0.8 * (1 - Float($0 % 12_000) / 200) : 0 }

    let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let package = home.appendingPathComponent("LoopStudio Projects/Perf 1000 Clips.loopstudio", isDirectory: true)
    try? FileManager.default.removeItem(at: package)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    var project = Project(name: "Perf 1000 Clips", sampleRate: rate)
    let tone = try AssetStore.importFile(toneURL, into: package), click = try AssetStore.importFile(clickURL, into: package)
    try Command.addAsset(asset: tone).apply(to: &project)
    try Command.addAsset(asset: click).apply(to: &project)
    let tracks = 50, perTrack = 20
    let t0 = Date()
    for t in 0..<tracks {
        let track = Track(name: "Track \(t + 1)", kind: .audio, volumeDb: -12, pan: Double(t % 5 - 2) * 0.2)
        try Command.insertTrack(track: track, index: project.tracks.count).apply(to: &project)
        for c in 0..<perTrack {
            // One bar each, two bars apart, offset by track so the arrangement is dense but not a wall.
            let start = Tick(Int64(c * 2 + t % 2) * 3840)
            var clip = project.makeAudioClip(asset: (t + c) % 3 == 0 ? click.id : tone.id, start: start, length: 3840)
            clip.fadeInMs = 2; clip.fadeOutMs = 2
            try Command.insertClip(track: track.id, clip: .audio(clip)).apply(to: &project)
        }
    }
    let built = Date().timeIntervalSince(t0)
    try ProjectPackage.write(project, to: package)
    let clips = project.tracks.reduce(0) { $0 + $1.clips.count }
    #expect(clips == tracks * perTrack)

    let loaded = AudioBank.load(project: project) { AssetStore.fileURL(for: $0, in: package) }
    let t1 = Date()
    let plan = RenderPlan.compile(project, bank: loaded.bank)
    let compiled = Date().timeIntervalSince(t1)
    let seconds = 30.0
    let before = resident()
    let t2 = Date()
    let audio = Bounce.render(plan, startFrame: 0, endFrame: Int64(seconds * rate), block: 512)
    let rendered = Date().timeIntervalSince(t2)
    let factor = seconds / rendered
    print(String(format: "PERF 1000 clips: %d tracks x %d clips built in %.3f s, plan compiled in %.3f s, %.0f s of audio rendered in %.2f s at 512-frame blocks = %.1f x realtime, +%.0f MB resident, peak %.2f",
                 tracks, perTrack, built, compiled, seconds, rendered, factor, Double(resident() - before) / 1e6, audio.left.max() ?? 0))
    print("PERF project written to \(package.path)")
    #expect(factor > 2, "a thousand clips must render at least twice as fast as realtime")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPSTUDIO_PERF"] == "1"))
func aOneHourFileDecodesAndPeaksInBoundedTime() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loopstudio-perf", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let url = tmp.appendingPathComponent("perf-one-hour.wav")
    let seconds = 3600.0
    if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < 600_000_000 }) ?? true {
        let t = Date()
        try writeWAV(seconds: seconds, to: url) { 0.5 * sinf(2 * .pi * 220 * Float($0) / Float(rate)) * sinf(Float($0) / 48_000) }
        print(String(format: "PERF 1 h file written in %.1f s", Date().timeIntervalSince(t)))
    }
    let before = resident()
    let t0 = Date()
    let pcm = try AudioBank.decode(url, targetRate: rate)
    let decoded = Date().timeIntervalSince(t0)
    let afterDecode = resident()
    #expect(pcm.frames == Int(seconds * rate))
    // The waveform peaks as the app draws them (vDSP): 1000 bins of max |sample| over the left channel.
    let left = pcm.channel(0)
    func peaks(_ bins: Int) -> [Float] {
        let per = max(1, pcm.frames / bins)
        return (0..<bins).map { b in
            let lo = b * per, count = min(pcm.frames, lo + per) - lo
            var m: Float = 0
            if count > 0 { vDSP_maxmgv(left + lo, 1, &m, vDSP_Length(count)) }
            return m
        }
    }
    let t1 = Date()
    let overview = peaks(1_000)
    let peaked = Date().timeIntervalSince(t1)
    // A finer pass at a high zoom: 50 bins per second over the whole hour.
    let t2 = Date()
    let fineMax = peaks(50 * 3600).max() ?? 0
    let fined = Date().timeIntervalSince(t2)
    #expect(overview.count == 1_000)
    print(String(format: "PERF 1 h file: decoded in %.2f s (+%.0f MB resident, %d frames), 1000 peaks in %.3f s, 180000 peaks in %.3f s, max %.2f",
                 decoded, Double(afterDecode - before) / 1e6, pcm.frames, peaked, fined, fineMax))
    #expect(decoded < 30, "a one-hour file must decode in under 30 s")
    #expect(peaked < 2, "the overview peaks of a one-hour file must take under 2 s")
}
