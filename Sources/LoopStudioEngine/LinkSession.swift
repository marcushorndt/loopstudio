import Foundation
import LinkBridge

/// Ableton Link: a shared tempo and beat grid with every Link app on the network, and (with
/// start/stop sync) a shared transport.
///
/// Link keeps its own timeline: a beat count against its clock, in microseconds of the Mac's host
/// clock. The app maps its song position onto that timeline when playback starts (`requestBeat`), reads
/// the tempo and the beat Link has reached, and writes the tempo and the transport state back. All of
/// that is the "app session state" API, used from one thread at a time under a lock. The audio thread
/// does not talk to Link: it plays frames, and the engine's own frame-to-host-time map does the rest.
public final class LinkSession: @unchecked Sendable {
    private let link: abl_link
    private let state: abl_link_session_state
    private let lock = NSLock()

    public init(bpm: Double) {
        link = abl_link_create(bpm)
        state = abl_link_create_session_state()
    }

    deinit {
        abl_link_enable(link, false)
        abl_link_destroy_session_state(state)
        abl_link_destroy(link)
    }

    /// On: the app is visible on the network and joins the session there.
    public var isEnabled: Bool {
        get { abl_link_is_enabled(link) }
        set { abl_link_enable(link, newValue) }
    }

    /// On: play and stop are shared with the peers that have it on too.
    public var startStopSync: Bool {
        get { abl_link_is_start_stop_sync_enabled(link) }
        set { abl_link_enable_start_stop_sync(link, newValue) }
    }

    /// Other Link apps in the session now.
    public var peers: Int { Int(abl_link_num_peers(link)) }

    /// Link's clock now, in microseconds.
    public var nowMicros: Int64 { abl_link_clock_micros(link) }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    /// Link's microseconds for a host time stamp (the same clock, as Link's Darwin clock scales it).
    public static func micros(fromHost host: UInt64) -> Int64 {
        Int64((Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1000).rounded())
    }

    public static func host(fromMicros micros: Int64) -> UInt64 {
        UInt64(max(0, (Double(micros) * 1000 * Double(timebase.denom) / Double(timebase.numer)).rounded()))
    }

    /// What the session holds now.
    public struct Snapshot: Equatable, Sendable {
        public var tempo: Double
        public var isPlaying: Bool
        /// When the transport last started or stopped, in Link microseconds.
        public var playTimeMicros: Int64
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        return Snapshot(tempo: abl_link_tempo(state), isPlaying: abl_link_is_playing(state),
                        playTimeMicros: abl_link_time_for_is_playing(state))
    }

    /// The beat Link has reached at `micros`, counted in quarter notes with `quantum` beats per bar.
    public func beat(atMicros micros: Int64, quantum: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        return abl_link_beat_at_time(state, micros, quantum)
    }

    /// Where in the bar of `quantum` beats Link stands at `micros`: 0 up to `quantum`.
    public func phase(atMicros micros: Int64, quantum: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        return abl_link_phase_at_time(state, micros, quantum)
    }

    public func setTempo(_ bpm: Double, atMicros micros: Int64) {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        abl_link_set_tempo(state, max(20, min(999, bpm)), micros)
        abl_link_commit_app_session_state(link, state)
    }

    public func setIsPlaying(_ playing: Bool, atMicros micros: Int64) {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        abl_link_set_is_playing(state, playing, micros)
        abl_link_commit_app_session_state(link, state)
    }

    /// Asks Link to put `beat` at `micros`. Alone in the session Link does just that; with peers it keeps
    /// their grid and gives the next time at or after `micros` with the same phase. Returns that time:
    /// when the song may start so that it sits on the shared grid. With `play` the transport state goes
    /// to "playing" at the same time, for the peers with start/stop sync.
    @discardableResult
    public func requestBeat(_ beat: Double, atMicros micros: Int64, quantum: Double, play: Bool = false) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        abl_link_capture_app_session_state(link, state)
        if play {
            abl_link_set_is_playing_and_request_beat_at_time(state, true, micros, beat, quantum)
        } else {
            abl_link_request_beat_at_time(state, beat, micros, quantum)
        }
        let time = abl_link_time_at_beat(state, beat, quantum)
        abl_link_commit_app_session_state(link, state)
        return time
    }
}
