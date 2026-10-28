import Foundation

// MARK: Assets

public struct Asset: Hashable, Codable, Sendable, Identifiable {
    public var id: AssetID
    /// SHA-256 of the file content, lowercase hex. The file name inside the package.
    public var sha256: String
    /// Original name, a label only.
    public var name: String
    public var frames: Int64
    public var sampleRate: Double
    public var channels: Int
    /// Tempo the loop was recorded at, if known (file metadata or analysis).
    public var sourceTempo: Double?

    public init(id: AssetID = AssetID(), sha256: String, name: String, frames: Int64,
                sampleRate: Double, channels: Int, sourceTempo: Double? = nil) {
        self.id = id
        self.sha256 = sha256
        self.name = name
        self.frames = frames
        self.sampleRate = sampleRate
        self.channels = channels
        self.sourceTempo = sourceTempo
    }
}

// MARK: Automation

public enum Curve: String, Codable, Sendable { case linear, hold, easeIn, easeOut, easeInOut }

public struct AutomationPoint: Hashable, Codable, Sendable {
    public var tick: Tick
    public var value: Double
    /// Shape of the segment that starts at this point.
    public var curve: Curve

    public init(tick: Tick, value: Double, curve: Curve = .linear) {
        self.tick = tick
        self.value = value
        self.curve = curve
    }
}

/// Names one parameter: a built-in track parameter or a plugin parameter.
public struct ParameterAddress: Hashable, Codable, Sendable {
    /// Track ID or device ID.
    public var node: UUID
    public var parameter: String

    public init(node: UUID, parameter: String) {
        self.node = node
        self.parameter = parameter
    }
}

public struct AutomationLane: Hashable, Codable, Sendable, Identifiable {
    public var id: LaneID
    public var target: ParameterAddress
    public var points: [AutomationPoint]

    public init(id: LaneID = LaneID(), target: ParameterAddress, points: [AutomationPoint] = []) {
        self.id = id
        self.target = target
        self.points = points
    }
}

// MARK: Clips

public enum WarpMode: String, Codable, Sendable { case off, beats, tones }

public struct WarpMarker: Hashable, Codable, Sendable {
    public var sourceFrame: Int64
    public var tick: Tick

    public init(sourceFrame: Int64, tick: Tick) {
        self.sourceFrame = sourceFrame
        self.tick = tick
    }
}

public struct AudioClip: Hashable, Codable, Sendable, Identifiable {
    /// Every clip gets a short fade at both edges, so nothing clicks. 0 means the user chose "no fade".
    public static let defaultFadeMs = 2.0

    public var id: ClipID
    public var asset: AssetID
    /// Position on the timeline. In a session slot this is 0 and unused.
    public var start: Tick
    public var length: Tick
    /// Where in the (warped) source the clip starts playing.
    public var offset: Tick
    public var loop: Bool
    public var gainDb: Double
    public var fadeInMs: Double
    public var fadeOutMs: Double
    public var muted: Bool
    public var warpMode: WarpMode
    public var warpMarkers: [WarpMarker]

    public init(id: ClipID = ClipID(), asset: AssetID, start: Tick = 0, length: Tick, offset: Tick = 0,
                loop: Bool = false, gainDb: Double = 0,
                fadeInMs: Double = AudioClip.defaultFadeMs, fadeOutMs: Double = AudioClip.defaultFadeMs,
                muted: Bool = false, warpMode: WarpMode = .off, warpMarkers: [WarpMarker] = []) {
        self.id = id
        self.asset = asset
        self.start = start
        self.length = length
        self.offset = offset
        self.loop = loop
        self.gainDb = gainDb
        self.fadeInMs = fadeInMs
        self.fadeOutMs = fadeOutMs
        self.muted = muted
        self.warpMode = warpMode
        self.warpMarkers = warpMarkers
    }
}

public struct MIDINote: Hashable, Codable, Sendable {
    /// Relative to the clip start.
    public var tick: Tick
    public var length: Tick
    public var pitch: UInt8
    public var velocity: UInt8
    public var channel: UInt8

    public init(tick: Tick, length: Tick, pitch: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        self.tick = tick
        self.length = length
        self.pitch = min(pitch, 127)
        self.velocity = min(max(velocity, 1), 127)
        self.channel = min(channel, 15)
    }
}

public struct MIDIClip: Hashable, Codable, Sendable, Identifiable {
    public var id: ClipID
    public var start: Tick
    public var length: Tick
    public var loop: Bool
    public var notes: [MIDINote]

    public init(id: ClipID = ClipID(), start: Tick = 0, length: Tick, loop: Bool = false, notes: [MIDINote] = []) {
        self.id = id
        self.start = start
        self.length = length
        self.loop = loop
        self.notes = notes
    }
}

/// A clip with no sound of its own. It takes up time in a block, carries follow actions,
/// and can hold automation lanes (ticks relative to the clip start). It is the "conductor" of a block.
public struct DummyClip: Hashable, Codable, Sendable, Identifiable {
    public var id: ClipID
    public var name: String
    public var start: Tick
    public var length: Tick
    public var lanes: [AutomationLane]

    public init(id: ClipID = ClipID(), name: String = "", start: Tick = 0, length: Tick, lanes: [AutomationLane] = []) {
        self.id = id
        self.name = name
        self.start = start
        self.length = length
        self.lanes = lanes
    }
}

public enum Clip: Hashable, Sendable, Identifiable {
    case audio(AudioClip)
    case midi(MIDIClip)
    case dummy(DummyClip)

    public var id: ClipID {
        switch self {
        case .audio(let c): c.id
        case .midi(let c): c.id
        case .dummy(let c): c.id
        }
    }

    public var start: Tick {
        switch self {
        case .audio(let c): c.start
        case .midi(let c): c.start
        case .dummy(let c): c.start
        }
    }

    public var length: Tick {
        switch self {
        case .audio(let c): c.length
        case .midi(let c): c.length
        case .dummy(let c): c.length
        }
    }

    public func with(start: Tick, length: Tick) -> Clip {
        switch self {
        case .audio(var c): c.start = start; c.length = length; return .audio(c)
        case .midi(var c): c.start = start; c.length = length; return .midi(c)
        case .dummy(var c): c.start = start; c.length = length; return .dummy(c)
        }
    }
}

extension Clip: Codable {
    private enum Key: String, CodingKey { case kind }
    private enum Kind: String, Codable { case audio, midi, dummy }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .audio: self = .audio(try AudioClip(from: decoder))
        case .midi: self = .midi(try MIDIClip(from: decoder))
        case .dummy: self = .dummy(try DummyClip(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .audio(let c): try container.encode(Kind.audio, forKey: .kind); try c.encode(to: encoder)
        case .midi(let c): try container.encode(Kind.midi, forKey: .kind); try c.encode(to: encoder)
        case .dummy(let c): try container.encode(Kind.dummy, forKey: .kind); try c.encode(to: encoder)
        }
    }
}

// MARK: Tracks

public enum TrackKind: String, Codable, Sendable { case audio, midi, group, returnTrack = "return", master }

/// A plugin or built-in effect on a track. The state blob is kept even when the plugin is missing.
public struct DeviceSlot: Hashable, Codable, Sendable, Identifiable {
    public var id: DeviceID
    /// "builtin" or "audiounit" (later "vst3").
    public var format: String
    /// Built-in effect ID, or "type/subtype/manufacturer" for an Audio Unit.
    public var identifier: String
    public var name: String
    public var bypassed: Bool
    /// Plugin state (Audio Unit full state, as a property list). Kept even when the plugin is missing.
    public var state: Data?
    /// Parameter values of a built-in effect. A missing key means the default.
    public var params: [String: Double]

    public init(id: DeviceID = DeviceID(), format: String, identifier: String, name: String,
                bypassed: Bool = false, state: Data? = nil, params: [String: Double] = [:]) {
        self.id = id
        self.format = format
        self.identifier = identifier
        self.name = name
        self.bypassed = bypassed
        self.state = state
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, format, identifier, name, bypassed, state, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DeviceID.self, forKey: .id)
        format = try c.decode(String.self, forKey: .format)
        identifier = try c.decode(String.self, forKey: .identifier)
        name = try c.decode(String.self, forKey: .name)
        bypassed = try c.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        state = try c.decodeIfPresent(Data.self, forKey: .state)
        params = try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
    }
}

public struct Send: Hashable, Codable, Sendable {
    public var target: TrackID
    public var levelDb: Double
    public var preFader: Bool

    public init(target: TrackID, levelDb: Double = 0, preFader: Bool = false) {
        self.target = target
        self.levelDb = levelDb
        self.preFader = preFader
    }
}

public struct Track: Hashable, Codable, Sendable, Identifiable {
    public static let dbRange: ClosedRange<Double> = -96...12

    public var id: TrackID
    public var name: String
    public var kind: TrackKind
    public var colorIndex: Int
    public var volumeDb: Double
    /// -1 (left) to 1 (right).
    public var pan: Double
    public var mute: Bool
    public var solo: Bool
    /// Arrangement clips, sorted by start tick, then by ID.
    public var clips: [Clip]
    /// Session slots, by scene index. `nil` means empty. Never ends with `nil`.
    public var slots: [SessionSlot?]
    public var devices: [DeviceSlot]
    public var sends: [Send]
    /// `nil` means the master track.
    public var output: TrackID?
    public var automation: [AutomationLane]
    /// Audio tracks: record or monitor from this input port.
    public var audioInput: PortID?
    /// MIDI tracks: which device and channel to listen to. `nil` means no MIDI input.
    public var midiInput: MIDIInputSelection?
    /// Sends the output straight to this hardware port, instead of to `output` or the master.
    /// On the master track this is the main speaker output.
    public var hardwareOutput: PortID?

    public init(id: TrackID = TrackID(), name: String, kind: TrackKind, colorIndex: Int = 0,
                volumeDb: Double = 0, pan: Double = 0, mute: Bool = false, solo: Bool = false,
                clips: [Clip] = [], slots: [SessionSlot?] = [], devices: [DeviceSlot] = [],
                sends: [Send] = [], output: TrackID? = nil, automation: [AutomationLane] = [],
                audioInput: PortID? = nil, midiInput: MIDIInputSelection? = nil, hardwareOutput: PortID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colorIndex = colorIndex
        self.volumeDb = volumeDb
        self.pan = pan
        self.mute = mute
        self.solo = solo
        self.clips = clips
        self.slots = slots
        self.devices = devices
        self.sends = sends
        self.output = output
        self.automation = automation
        self.audioInput = audioInput
        self.midiInput = midiInput
        self.hardwareOutput = hardwareOutput
    }

    /// Inserts a clip at its sorted place, so the order never depends on insertion history.
    mutating func insertSorted(_ clip: Clip) {
        let index = clips.firstIndex { other in
            (other.start, other.id.description) > (clip.start, clip.id.description)
        } ?? clips.count
        clips.insert(clip, at: index)
    }

    mutating func trimTrailingEmptySlots() {
        while let last = slots.last, last == nil { slots.removeLast() }
    }
}

// MARK: Project

public struct Marker: Hashable, Codable, Sendable, Identifiable {
    public var id: MarkerID
    public var tick: Tick
    public var name: String

    public init(id: MarkerID = MarkerID(), tick: Tick, name: String) {
        self.id = id
        self.tick = tick
        self.name = name
    }
}

public struct LoopRegion: Hashable, Codable, Sendable {
    public var start: Tick
    public var end: Tick
    public var enabled: Bool

    public init(start: Tick, end: Tick, enabled: Bool = true) {
        self.start = start
        self.end = end
        self.enabled = enabled
    }
}

/// Decides whether a sample loops or plays once when it is dropped into the timeline or a slot.
/// Short samples (loops) repeat. Long samples (songs, vocals, ambience) play once.
/// The user can still change the flag on any clip afterwards.
public struct AutoLoopRule: Hashable, Codable, Sendable {
    public var enabled: Bool
    /// Samples shorter than this play once (single hits). 0 turns the lower limit off.
    public var minSeconds: Double
    /// Samples longer than this play once.
    public var maxSeconds: Double

    public init(enabled: Bool = true, minSeconds: Double = 0, maxSeconds: Double = 20) {
        self.enabled = enabled
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
    }

    /// With the rule off, every dropped sample plays once.
    public func shouldLoop(seconds: Double) -> Bool {
        guard enabled, seconds.isFinite else { return false }
        return seconds >= minSeconds && seconds <= maxSeconds
    }
}

public struct Project: Hashable, Codable, Sendable {
    public var name: String
    public var sampleRate: Double
    public var tempoMap: TempoMap
    public var timeSignatures: [TimeSignatureChange]
    public var markers: [Marker]
    public var loop: LoopRegion?
    /// Seed for follow-action choices. Same seed, same choices: bounces repeat exactly.
    public var randomSeed: UInt32
    /// Fade length for new audio clips, in milliseconds.
    public var defaultFadeMs: Double
    public var autoLoop: AutoLoopRule
    /// Logical hardware ports. The project names them; each machine maps them to real channels.
    public var ports: [IOPort]
    /// Session launches over time (see `Launch`), sorted by tick.
    public var launches: [Launch]
    public var assets: [Asset]
    public var tracks: [Track]
    public var master: Track

    public init(name: String, sampleRate: Double = 48_000) {
        self.name = name
        self.sampleRate = sampleRate
        self.tempoMap = TempoMap()
        self.timeSignatures = [TimeSignatureChange(tick: 0, signature: TimeSignature(4, 4))]
        self.markers = []
        self.loop = nil
        self.randomSeed = 1
        self.defaultFadeMs = AudioClip.defaultFadeMs
        self.autoLoop = AutoLoopRule()
        self.assets = []
        self.tracks = []
        self.master = Track(name: "Master", kind: .master)
        let main = IOPort(name: "Main", direction: .output, channels: 2)
        self.ports = [main,
                      IOPort(name: "Cue", direction: .output, channels: 2),
                      IOPort(name: "Input 1-2", direction: .input, channels: 2)]
        self.master.hardwareOutput = main.id
        self.launches = []
    }

    /// Ports that some track uses. The resolver reports only these as unmapped.
    public var usedPortIDs: Set<PortID> {
        Set(allTracks.flatMap { [$0.hardwareOutput, $0.audioInput] }.compactMap { $0 })
    }

    public var allTracks: [Track] { tracks + [master] }

    public func track(_ id: TrackID) -> Track? {
        master.id == id ? master : tracks.first { $0.id == id }
    }

    public func asset(_ id: AssetID) -> Asset? { assets.first { $0.id == id } }

    /// A new audio clip for a dropped sample. It gets the project's default fade (nothing clicks)
    /// and the loop or one-shot setting from the auto-loop rule, judged by the sample's duration.
    public func makeAudioClip(asset assetID: AssetID, start: Tick = 0, length: Tick) -> AudioClip {
        var loop = false
        if let asset = asset(assetID), asset.sampleRate > 0 {
            loop = autoLoop.shouldLoop(seconds: Double(asset.frames) / asset.sampleRate)
        }
        return AudioClip(asset: assetID, start: start, length: length, loop: loop,
                         fadeInMs: defaultFadeMs, fadeOutMs: defaultFadeMs)
    }

    /// Finds a clip in the arrangement or in a session slot.
    public func findClip(_ id: ClipID) -> (track: TrackID, clip: Clip)? {
        for t in allTracks {
            if let c = t.clips.first(where: { $0.id == id }) { return (t.id, c) }
            for case let slot? in t.slots where slot.clip.id == id { return (t.id, slot.clip) }
        }
        return nil
    }

    mutating func withTrack<T>(_ id: TrackID, _ body: (inout Track) throws -> T) throws -> T {
        if master.id == id { return try body(&master) }
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw CommandError.trackNotFound(id) }
        return try body(&tracks[i])
    }
}
