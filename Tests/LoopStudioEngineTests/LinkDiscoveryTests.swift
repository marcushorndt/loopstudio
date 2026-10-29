import Foundation
import Testing
@testable import LoopStudioEngine

/// Two sessions in one process find each other over the local network (UDP multicast on the loopback
/// and the real interfaces). Set `LOOPSTUDIO_LINK_NET=1` to run it: it needs the local network permission.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPSTUDIO_LINK_NET"] == "1"))
func twoSessionsOnThisMacFindEachOther() async throws {
    let a = LinkSession(bpm: 120), b = LinkSession(bpm: 120)
    a.isEnabled = true
    b.isEnabled = true
    var waited = 0
    while a.peers == 0, waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
    #expect(a.peers >= 1 && b.peers >= 1, "a sees \(a.peers), b sees \(b.peers) after \(waited / 10) s")
    a.setTempo(99, atMicros: a.nowMicros)
    waited = 0
    while abs(b.snapshot().tempo - 99) > 0.01, waited < 50 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
    #expect(abs(b.snapshot().tempo - 99) < 0.01, "the tempo reached the other session")
}

/// A hand tool, not a test: `LOOPSTUDIO_LINK_SET_TEMPO=120` sets that tempo in the Link session on this Mac
/// for a few seconds, so a running app that follows Link takes it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPSTUDIO_LINK_SET_TEMPO"] != nil))
func setTheSessionTempoFromHere() async throws {
    let bpm = Double(ProcessInfo.processInfo.environment["LOOPSTUDIO_LINK_SET_TEMPO"] ?? "") ?? 120
    let s = LinkSession(bpm: bpm)
    s.isEnabled = true
    var waited = 0
    while s.peers == 0, waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
    s.setTempo(bpm, atMicros: s.nowMicros)
    try await Task.sleep(for: .seconds(2))
    #expect(s.peers >= 1, "no app on this Mac has Link on")
}

/// A hand tool: `LOOPSTUDIO_LINK_PEERS=1` joins the session for five seconds and prints who is there.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOOPSTUDIO_LINK_PEERS"] == "1"))
func printTheSessionPeers() async throws {
    let s = LinkSession(bpm: 120)
    s.isEnabled = true
    for second in 1...5 {
        try await Task.sleep(for: .seconds(1))
        print("LINK after \(second) s: \(s.peers) peer(s), tempo \(s.snapshot().tempo), playing \(s.snapshot().isPlaying)")
    }
}
