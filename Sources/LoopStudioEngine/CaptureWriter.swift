import AVFoundation
import Foundation
import LoopStudioCore

/// The tracks a resampling take records, with the ring of each writer. Built on the control thread; the audio
/// thread only reads it. `nil` as a track is the master.
public final class CaptureSet: @unchecked Sendable {
    let tracks: [TrackID?]
    let rings: [CaptureRing]
    var count: Int { tracks.count }
    public init(_ entries: [(track: TrackID?, writer: CaptureWriter)]) {
        tracks = entries.map(\.track)
        rings = entries.map(\.writer.ring)
    }
}

/// Moves captured audio from a `CaptureRing` into a file on a writer queue, every 20 ms.
///
/// The producer (an input tap, or the renderer when a track records another track) only writes the
/// ring. Slow storage can therefore never hold it up; what does not fit is counted as dropped.
public final class CaptureWriter: @unchecked Sendable {
    public struct Result: Sendable {
        public var frames: Int64
        public var droppedFrames: Int64
        public var writeError: String?
        /// Host time of the first buffer, for an input tap. 0 when unknown.
        public var firstHostTime: UInt64
        /// Timeline frame of the first frame, for audio from the renderer. `nil` for an input tap.
        public var firstFrame: Int64?
    }

    let ring: CaptureRing
    public let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let chunk: AVAudioPCMBuffer
    private var written: Int64 = 0
    private var writeError: String?
    private let queue = DispatchQueue(label: "loopstudio.capture.writer", qos: .userInitiated)
    private let timer: DispatchSourceTimer

    /// Ten seconds of ring by default: far more than a slow disk needs to catch up.
    public init(url: URL, sampleRate: Double, channels: Int, ringSeconds: Double = 10) throws {
        let channels = max(1, min(2, channels))
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.chunk = chunk
        ring = CaptureRing(channels: channels, capacity: Int(sampleRate * ringSeconds))
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
    }

    /// Stops the writer, writes what is left, and closes the file. Call after the producer has stopped.
    public func finish() -> Result {
        timer.cancel()
        queue.sync { drain() }
        lock.lock(); defer { lock.unlock() }
        file = nil // closes the file
        return Result(frames: written, droppedFrames: Int64(ring.dropped), writeError: writeError,
                      firstHostTime: ring.startHostTime, firstFrame: ring.startFrame)
    }

    /// Writer queue. The disk write runs outside the lock.
    private func drain() {
        lock.lock()
        let file = file
        lock.unlock()
        guard let file, let dst = chunk.floatChannelData else { return }
        while true {
            let n = ring.read(into: dst[0], ring.channels == 2 ? dst[1] : nil, max: Int(chunk.frameCapacity))
            guard n > 0 else { return }
            chunk.frameLength = AVAudioFrameCount(n)
            var failure: String?
            do { try file.write(from: chunk) } catch { failure = error.localizedDescription }
            lock.lock()
            if let failure { if writeError == nil { writeError = failure } } else { written += Int64(n) }
            lock.unlock()
        }
    }
}
