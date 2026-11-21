import AVFoundation
import Foundation
import Testing
@testable import LoopStudioCore
@testable import LoopStudioProject

func writeTestWAV(seconds: Double, rate: Double = 48_000, amplitude: Float = 0.5, frequency: Float = 440) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    let n = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buffer.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { buffer.floatChannelData![c][i] = amplitude * sinf(2 * .pi * frequency * Float(i) / Float(rate)) } }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                          AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24])
    try file.write(from: buffer)
    return url
}

@Test func importCopiesByHashAndDescribesTheFile() throws {
    let package = Temp.directory()
    let source = try writeTestWAV(seconds: 1.5, rate: 44_100)
    let asset = try AssetStore.importFile(source, into: package)
    #expect(asset.sha256.count == 64)
    #expect(asset.frames == 66_150 && asset.sampleRate == 44_100 && asset.channels == 2)
    #expect(asset.name == source.lastPathComponent)
    let stored = try #require(AssetStore.fileURL(for: asset, in: package))
    #expect(stored.lastPathComponent == "\(asset.sha256).wav")
    #expect(try AssetStore.sha256(of: stored) == asset.sha256, "the copy has the same content")
}

@Test func theSameFileIsStoredOnce() throws {
    let package = Temp.directory()
    let a = try writeTestWAV(seconds: 0.5)
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString).wav")
    try FileManager.default.copyItem(at: a, to: copy)
    let first = try AssetStore.importFile(a, into: package)
    let second = try AssetStore.importFile(copy, into: package)
    #expect(first.sha256 == second.sha256)
    #expect(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("audio").path).count == 1)
}

@Test func differentFilesGetDifferentHashes() throws {
    let a = try AssetStore.sha256(of: writeTestWAV(seconds: 0.5, frequency: 440))
    let b = try AssetStore.sha256(of: writeTestWAV(seconds: 0.5, frequency: 441))
    #expect(a != b)
}

@Test func nonAudioFilesAreRefused() throws {
    let package = Temp.directory()
    let text = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).wav")
    try Data("this is not audio".utf8).write(to: text)
    #expect(throws: AssetStore.StoreError.self) { try AssetStore.importFile(text, into: package) }
    #expect(throws: (any Error).self) { try AssetStore.importFile(URL(fileURLWithPath: "/nonexistent/x.wav"), into: package) }
}

@Test func lookupMatchesTheWholeHash() throws {
    let package = Temp.directory()
    let asset = try AssetStore.importFile(writeTestWAV(seconds: 0.5), into: package)
    var other = asset
    other.sha256 = String(asset.sha256.prefix(10))
    #expect(AssetStore.fileURL(for: other, in: package) == nil, "a prefix of the hash is not the file")
    other.sha256 = String(repeating: "0", count: 64)
    #expect(AssetStore.fileURL(for: other, in: package) == nil)
}

/// The side files beside an audio file (`.notes` sorts before `.wav`) are never taken for the audio, and
/// `files(for:)` lists the audio with its side files.
@Test func sideFilesAreNotTheAudio() throws {
    let package = Temp.directory()
    let asset = try AssetStore.importFile(writeTestWAV(seconds: 0.5), into: package)
    let notes = AssetStore.sidecarURL(sha256: asset.sha256, ext: "notes", in: package)
    let warp = AssetStore.sidecarURL(sha256: asset.sha256, ext: "warp", in: package)
    try Data("x".utf8).write(to: notes)
    try Data("y".utf8).write(to: warp)
    #expect(AssetStore.fileURL(for: asset, in: package)?.lastPathComponent == "\(asset.sha256).wav")
    #expect(Set(AssetStore.files(for: asset, in: package).map(\.lastPathComponent))
            == ["\(asset.sha256).wav", "\(asset.sha256).notes", "\(asset.sha256).warp"])
}
