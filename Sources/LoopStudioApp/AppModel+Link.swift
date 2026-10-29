import Foundation
import LoopStudioCore
import LoopStudioEngine

/// Ableton Link, like the Link button in Live.
///
/// Tempo goes both ways: a change here goes to the session at once, a change from a peer comes in with
/// the next poll (ten times a second) and goes into the project without an undo entry. Play puts the song
/// position on the shared grid: alone, at once; with peers, at the next time with the same phase in the
/// bar. With start/stop sync a peer's play or stop drives the transport here, and ours drives theirs.
/// While playing, the phase is checked ten times a second: a drift (the sound card's clock against the
/// Mac's) is made up by a tempo nudge of at most half a percent; a jump of more than half a beat (the
/// song was moved) jumps back onto the grid.
extension AppModel {
    /// Beats per bar in quarter notes: Link's quantum.
    var linkQuantum: Double { Double(meter.beats) * Double(meter.beatTicks) / Double(Tick.perQuarter) }

    /// Starts or stops the session after a settings change or at launch.
    func applyLinkSettings() {
        link.startStopSync = linkStartStop
        link.isEnabled = linkEnabled
        linkTask?.cancel()
        linkTask = nil
        setLinkPeers(0)
        guard linkEnabled else { return }
        linkTempoKnown = bpm
        link.setTempo(bpm, atMicros: link.nowMicros)
        linkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.linkTick()
            }
        }
    }

    /// One poll of the session.
    func linkTick() {
        let snap = link.snapshot()
        setLinkPeers(link.peers)
        if abs(snap.tempo - linkTempoKnown) >= 0.005 {
            linkTempoKnown = snap.tempo
            if abs(snap.tempo - bpm) >= 0.005 { followTempo(snap.tempo) }
        }
        if linkStartStop {
            if snap.isPlaying, !transportPlaying, !recordArmed {
                playFromLink(at: snap.playTimeMicros)
            } else if !snap.isPlaying, transportPlaying {
                linkFollowing = true
                pause()
                linkFollowing = false
            }
        }
        if transportPlaying, !engine.isCountingIn { keepLinkPhase(tempo: snap.tempo) }
    }

    /// Asks the session for our song position and starts the engine at the time Link gives. False without Link.
    func playOnLinkGrid() -> Bool {
        guard linkEnabled else { return false }
        let beat = Double(currentTick.rawValue) / Double(Tick.perQuarter)
        // A little ahead, so the audio thread sees the start time before it is due.
        let start = link.requestBeat(beat, atMicros: link.nowMicros + 50_000, quantum: linkQuantum, play: linkStartStop)
        engine.play(atHost: LinkSession.host(fromMicros: start))
        return true
    }

    /// A peer started the transport at `micros`: come in on the shared grid, from the bar the song stands in.
    func playFromLink(at micros: Int64) {
        let at = max(micros, link.nowMicros + 50_000)
        let phase = link.phase(atMicros: at, quantum: linkQuantum)
        let bar = (currentTick.rawValue / barTicks) * barTicks
        let tick = Tick(bar + Int64((phase * Double(Tick.perQuarter)).rounded()))
        linkFollowing = true
        seek(to: tick)
        resumeSession()
        engine.play(atHost: LinkSession.host(fromMicros: at))
        transportPlaying = true
        startClockAfterCountIn()
        linkFollowing = false
    }

    /// Keeps the song on the session's beat grid while it plays.
    private func keepLinkPhase(tempo linkTempo: Double) {
        // An arrangement loop that is not whole bars moves the phase on purpose: leave it alone.
        if let loop = project.loop, loop.enabled {
            guard loop.start.rawValue % barTicks == 0, (loop.end.rawValue - loop.start.rawValue) % barTicks == 0 else { return }
        }
        let host = mach_absolute_time()
        let q = linkQuantum
        let linkBeat = link.beat(atMicros: LinkSession.micros(fromHost: host), quantum: q)
        let sessionAt = engine.sessionFrame(atHost: host)
        let frameAt = engine.positionFrame + (sessionAt - engine.sessionFrame)
        let ourBeat = Double(project.tempoMap.tick(atFrame: Frame(frameAt), sampleRate: sampleRate).rawValue) / Double(Tick.perQuarter)
        var drift = (linkBeat - ourBeat).truncatingRemainder(dividingBy: q)
        if drift > q / 2 { drift -= q } else if drift < -q / 2 { drift += q }
        if abs(drift) > 0.5 {
            seek(to: Tick(max(0, Int64(((ourBeat + drift) * Double(Tick.perQuarter)).rounded()))))
            return
        }
        let current = bpm
        if abs(drift) > 1.0 / 64 {
            let factor = max(0.995, min(1.005, 1 + drift * 0.25))
            let target = ((linkTempo * factor) * 100).rounded() / 100
            if abs(target - current) >= 0.01 { followTempo(target) }
        } else if abs(drift) < 1.0 / 256, abs(current - linkTempo) >= 0.005 {
            followTempo(linkTempo)
        }
    }
}
