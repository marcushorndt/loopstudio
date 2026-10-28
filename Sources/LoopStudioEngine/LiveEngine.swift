import AVFoundation
import Foundation
import LoopStudioCore
import os

/// Plays a `Renderer` through the default output device.
///
/// The audio thread only reads state under a try-lock. If the lock is busy (the control thread swaps
/// the renderer), that block is silent. The control thread holds the lock for a few pointer writes only.
public final class LiveEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Guarded by `lock`.
    private var renderer: Renderer?
    private var playing = false
    private var position: Int64 = 0
    private var loop: Range<Int64>?
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        engine.stop()
        lock.deallocate()
    }

    public func start() throws {
        guard sourceNode == nil else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    public func shutdown() { engine.stop() }

    // MARK: Control thread

    public func setRenderer(_ new: Renderer?) {
        os_unfair_lock_lock(lock)
        let old = renderer
        renderer = new
        os_unfair_lock_unlock(lock)
        withExtendedLifetime(old) {}
    }

    public var isPlaying: Bool { locked { playing } }
    /// The next frame to play.
    public var positionFrame: Int64 { locked { position } }

    public func play() { locked { playing = true } }
    public func pause() { locked { playing = false } }
    public func seek(to frame: Int64) { locked { position = max(0, frame) } }
    public func setLoop(_ range: Range<Int64>?) { locked { loop = range } }

    public func takePeak(node: Int) -> Float { locked { renderer?.takePeak(node: node) ?? 0 } }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: Audio thread

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        guard os_unfair_lock_trylock(lock) else {
            left.update(repeating: 0, count: frameCount); right.update(repeating: 0, count: frameCount)
            return
        }
        defer { os_unfair_lock_unlock(lock) }

        guard playing, let renderer else {
            left.update(repeating: 0, count: frameCount); right.update(repeating: 0, count: frameCount)
            return
        }

        var done = 0
        while done < frameCount {
            var n = min(frameCount - done, renderer.maxBlock)
            if let loop, position < loop.upperBound {
                n = min(n, Int(loop.upperBound - position))
            }
            renderer.process(startFrame: position, frames: n, outLeft: left + done, outRight: right + done)
            position += Int64(n)
            done += n
            if let loop, position >= loop.upperBound { position = loop.lowerBound }
        }
    }
}
