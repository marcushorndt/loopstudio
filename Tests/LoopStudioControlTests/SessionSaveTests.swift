import Foundation
import Testing
import LoopStudioCore
@testable import LoopStudioControl

@Test func editsDuringSavesAreNeverLost() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString).loopstudio")
    defer { try? FileManager.default.removeItem(at: url) }
    let session = ProjectSession()
    try await session.create(at: url, name: "S", sampleRate: 48_000)

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for i in 0..<40 { try? await session.apply(.setTempoPoints(points: [TempoPoint(tick: 0, bpm: 80 + Double(i))])) }
        }
        group.addTask {
            for _ in 0..<20 { try? await session.save() }
        }
    }
    let memory = try await session.project()
    // A crash now: the disk plus the journal must give the same project as memory.
    let reopened = ProjectSession()
    try await reopened.open(at: url)
    #expect(try await reopened.project().tempoMap == memory.tempoMap)
}
