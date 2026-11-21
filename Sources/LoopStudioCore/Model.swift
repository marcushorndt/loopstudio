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
    /// The tempo the analysis found (the file name, the loop length or the beats). It stays when the source
    /// tempo is changed by hand or by Fit, so the clip panel can show it and go back to it.
    public var detectedTempo: Double?
    /// A note render (`NoteEdit`): the original it was rendered from. A render that no clip plays any more
    /// is removed from the project on save.
    public var renderOf: AssetID?

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
    /// Slope of a linear segment, -1...1. Positive: the segment moves fast first, then slowly.
    /// Negative: slowly first, then fast. `nil` or 0: straight.
    public var bend: Double?

    public init(tick: Tick, value: Double, curve: Curve = .linear, bend: Double? = nil) {
        self.tick = tick
        self.value = value
        self.curve = curve
        self.bend = bend
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

    /// In the lanes of an audio or MIDI clip: "the track that holds the clip". A mixer lane with this node
    /// moves with the clip to another track.
    public static let ownTrack = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The address with `ownTrack` replaced by the track that holds the clip.
    public func resolved(owner: TrackID) -> ParameterAddress {
        node == Self.ownTrack ? ParameterAddress(node: owner.rawValue, parameter: parameter) : self
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

/// How a clip follows the project tempo. `off` plays the file as it is. The others stretch it, each with its
/// own method, cheapest first:
/// - `repitch`: speed and pitch change together, like a tape or a turntable.
/// - `beats`: the audio is cut at its transients (or on a grid) and every piece plays at its own speed; gaps
///   fill by looping the end of a piece. For drums and percussive loops.
/// - `tones`: overlapping grains, aligned to the waveform. For a single voice, bass or lead.
/// - `texture`: grains without alignment, with a random spread (Flux). For pads, noise and ambience.
/// - `complex`: a phase vocoder (Rubber Band R2). For full mixes and polyphonic material.
/// - `complexPro`: the finer phase vocoder (Rubber Band R3) with formant control. The best result, and the most CPU.
public enum WarpMode: String, Codable, Sendable, CaseIterable {
    case off, beats, tones, texture, repitch, complex, complexPro

    /// The modes a warped clip can use, in the order of the menu.
    public static let stretching: [WarpMode] = [.beats, .tones, .texture, .repitch, .complex, .complexPro]

    public var title: String {
        switch self {
        case .off: "Off"
        case .beats: "Beats"
        case .tones: "Tones"
        case .texture: "Texture"
        case .repitch: "Re-Pitch"
        case .complex: "Complex"
        case .complexPro: "Complex Pro"
        }
    }

    /// False for Re-Pitch, where the pitch follows the speed and Transpose has no effect.
    public var keepsPitch: Bool { self != .repitch }
}

/// The settings of the warp modes. Each mode reads its own; they all stay with the clip, so a switch back
/// finds them again. Every field has a default, and a project without them reads as the defaults.
public struct WarpSettings: Hashable, Codable, Sendable {
    /// Where Beats cuts the audio: at the detected transients, or on a note grid of the source.
    public enum Preserve: String, Codable, Sendable, CaseIterable {
        case transients, quarter, eighth, sixteenth, thirtySecond
        /// Grid step in beats. `nil` for transients.
        public var beats: Double? {
            switch self {
            case .transients: nil
            case .quarter: 1
            case .eighth: 0.5
            case .sixteenth: 0.25
            case .thirtySecond: 0.125
            }
        }
        public var title: String {
            switch self {
            case .transients: "Transients"
            case .quarter: "1/4"
            case .eighth: "1/8"
            case .sixteenth: "1/16"
            case .thirtySecond: "1/32"
            }
        }
    }

    /// How Beats fills the gap when a piece is shorter than its slot (a slower tempo).
    public enum TransientLoop: String, Codable, Sendable, CaseIterable {
        /// The piece plays once; the rest of the slot is silent.
        case off
        /// The second half of the piece loops forward.
        case forward
        /// The second half of the piece plays forward and back.
        case backAndForth
        public var title: String {
            switch self {
            case .off: "Silence"
            case .forward: "Loop Forward"
            case .backAndForth: "Back and Forth"
            }
        }
    }

    public var preserve: Preserve = .transients
    public var transientLoop: TransientLoop = .forward
    /// Beats: 100 plays each piece at full level to its end; lower values fade every piece out sooner. 0...100.
    public var transientEnvelope: Double = 100
    /// Tones: the grain length in milliseconds. 5...200.
    public var tonesGrainMs: Double = 40
    /// Texture: the grain length in milliseconds. 10...500.
    public var textureGrainMs: Double = 100
    /// Texture: how far grains wander from their place, 0...100 % of a grain.
    public var flux: Double = 0
    /// Complex Pro: how much the formants stay where they are when the pitch moves, 0...100 %.
    public var formants: Double = 100
    /// Semitones, -48...48. Every mode but Re-Pitch.
    public var transpose: Int = 0
    /// Cents, -50...50. Every mode but Re-Pitch.
    public var detune: Double = 0

    public init() {}

    public static let ranges: (tonesGrainMs: ClosedRange<Double>, textureGrainMs: ClosedRange<Double>, percent: ClosedRange<Double>,
                               transpose: ClosedRange<Int>, detune: ClosedRange<Double>) =
        (5...200, 10...500, 0...100, -48...48, -50...50)

    /// The values, each kept inside its range.
    public var clamped: WarpSettings {
        var s = self
        let r = Self.ranges
        s.transientEnvelope = min(max(s.transientEnvelope, r.percent.lowerBound), r.percent.upperBound)
        s.tonesGrainMs = min(max(s.tonesGrainMs, r.tonesGrainMs.lowerBound), r.tonesGrainMs.upperBound)
        s.textureGrainMs = min(max(s.textureGrainMs, r.textureGrainMs.lowerBound), r.textureGrainMs.upperBound)
        s.flux = min(max(s.flux, r.percent.lowerBound), r.percent.upperBound)
        s.formants = min(max(s.formants, r.percent.lowerBound), r.percent.upperBound)
        s.transpose = min(max(s.transpose, r.transpose.lowerBound), r.transpose.upperBound)
        s.detune = min(max(s.detune, r.detune.lowerBound), r.detune.upperBound)
        return s
    }

    /// The settings that change the sound of `mode`, as text for a cache key: a change to another mode's
    /// settings does not render the clip again.
    public func key(for mode: WarpMode) -> String {
        let pitch = mode.keepsPitch ? " t\(transpose) d\(detune)" : ""
        switch mode {
        case .off, .repitch: return "-"
        case .beats: return "\(preserve.rawValue) \(transientLoop.rawValue) e\(transientEnvelope)" + pitch
        case .tones: return "g\(tonesGrainMs)" + pitch
        case .texture: return "g\(textureGrainMs) f\(flux)" + pitch
        case .complex: return "c" + pitch
        case .complexPro: return "f\(formants)" + pitch
        }
    }

    /// The pitch as a frequency ratio: 2 is an octave up.
    public var pitchRatio: Double { pow(2, (Double(transpose) + detune / 100) / 12) }

    enum CodingKeys: String, CodingKey {
        case preserve, transientLoop, transientEnvelope, tonesGrainMs, textureGrainMs, flux, formants, transpose, detune
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WarpSettings()
        preserve = try c.decodeIfPresent(Preserve.self, forKey: .preserve) ?? d.preserve
        transientLoop = try c.decodeIfPresent(TransientLoop.self, forKey: .transientLoop) ?? d.transientLoop
        transientEnvelope = try c.decodeIfPresent(Double.self, forKey: .transientEnvelope) ?? d.transientEnvelope
        tonesGrainMs = try c.decodeIfPresent(Double.self, forKey: .tonesGrainMs) ?? d.tonesGrainMs
        textureGrainMs = try c.decodeIfPresent(Double.self, forKey: .textureGrainMs) ?? d.textureGrainMs
        flux = try c.decodeIfPresent(Double.self, forKey: .flux) ?? d.flux
        formants = try c.decodeIfPresent(Double.self, forKey: .formants) ?? d.formants
        transpose = try c.decodeIfPresent(Int.self, forKey: .transpose) ?? d.transpose
        detune = try c.decodeIfPresent(Double.self, forKey: .detune) ?? d.detune
    }
}

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
    /// Where in the (warped) source the clip starts playing: the start marker.
    public var offset: Tick
    public var loop: Bool
    /// Start of the loop, in the same ticks as `offset`. Playback begins at `offset` and runs into the loop, so
    /// the start can sit before the loop (an intro) or inside it. `nil`: the loop starts at `offset` in a
    /// session slot and at the file start on the timeline. See `loopRegion`.
    public var loopStart: Tick?
    /// Length of the loop. `nil`: the clip length in a session slot, up to the end of the file on the timeline.
    public var loopLength: Tick?
    public var gainDb: Double
    public var fadeInMs: Double
    public var fadeOutMs: Double
    public var muted: Bool
    public var warpMode: WarpMode
    public var warpMarkers: [WarpMarker]
    /// The settings of the warp modes. `nil`: the defaults. Read them through `warp`.
    public var warpSettings: WarpSettings?
    /// Own colour, an index into the palette. `nil` follows the track.
    public var colorIndex: Int?
    /// Own name. `nil` shows the asset name (audio) or a default.
    public var name: String?
    /// Clip gain envelope in dB, ticks from the clip start. It multiplies with `gainDb`. `nil` or empty: none.
    public var gainEnvelope: [AutomationPoint]?
    /// Clip automation of the track's parameters, ticks from the clip start. `nil`: none. See `Clip.lanes`.
    public var lanes: [AutomationLane]?
    /// Length of one cycle of the clip automation. `nil`: linked to the clip length (it loops with the clip).
    /// Set, it runs on its own: a 16-bar curve over a 1-bar loop.
    public var automationLength: Tick?
    /// Notes changed in the file, Melodyne-like. `nil`: none. With it, `asset` is the file rendered from
    /// `noteEdit.source` with the changes.
    public var noteEdit: NoteEdit?

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

public extension AudioClip {
    /// The warp settings in force: the clip's own, or the defaults.
    var warp: WarpSettings { warpSettings ?? WarpSettings() }

    /// True when the loop has a start or a length of its own, apart from the start marker.
    var ownLoop: Bool { loopStart != nil || loopLength != nil }

    /// The part of the file that repeats: its start and its length (`nil`: up to the end of the file).
    /// `session`: the clip sits in a session slot, where the clip length is the loop length.
    func loopRegion(session: Bool) -> (start: Tick, length: Tick?) {
        (loopStart ?? (session ? offset : 0), loopLength ?? (session ? length : nil))
    }

    /// The tick in the file that sounds `elapsed` after the clip starts: from the start marker on, and once
    /// it reaches the loop end, round the loop. `fileTicks` is the length of the file in the same ticks.
    func playTick(after elapsed: Tick, session: Bool, fileTicks: Tick) -> Tick {
        var t = offset.rawValue + elapsed.rawValue
        guard loop else { return Tick(t) }
        let r = loopRegion(session: session)
        let start = r.start.rawValue, length = r.length?.rawValue ?? (fileTicks.rawValue - start)
        guard length > 0 else { return Tick(t) }
        if t >= start + length || t < 0 { t = start + ((t - start) % length + length) % length }
        return Tick(t)
    }
}

public extension Array where Element == MIDINote {
    /// The notes sorted, with no two notes of one pitch and channel overlapping. A note that runs into the
    /// next note of its pitch ends where that note starts; a note that starts where another already starts
    /// replaces it (the later one in the list wins, so a dropped or moved note takes the place).
    func withoutOverlaps() -> [MIDINote] {
        var byLane: [UInt16: [MIDINote]] = [:]
        for n in self { byLane[UInt16(n.channel) << 8 | UInt16(n.pitch), default: []].append(n) }
        var out: [MIDINote] = []
        for lane in byLane.values {
            // The original order breaks ties, so for two notes at one tick the later one in the list stays.
            let ordered = lane.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)
            var kept: [MIDINote] = []
            for n in ordered {
                if let last = kept.last, last.tick == n.tick { kept.removeLast() }
                if var last = kept.last, last.tick + last.length > n.tick {
                    last.length = n.tick - last.tick
                    kept[kept.count - 1] = last
                }
                kept.append(n)
            }
            out += kept
        }
        return out.sorted { ($0.tick, $0.pitch, $0.channel) < ($1.tick, $1.pitch, $1.channel) }
    }
}

public struct MIDINote: Hashable, Codable, Sendable {
    /// Relative to the clip start.
    public var tick: Tick
    public var length: Tick
    public var pitch: UInt8
    public var velocity: UInt8
    public var channel: UInt8
    /// A muted note stays in the clip but does not play. Like a deactivated note in Live (the 0 key).
    public var muted: Bool

    public init(tick: Tick, length: Tick, pitch: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0, muted: Bool = false) {
        self.tick = tick
        self.length = length
        self.pitch = min(pitch, 127)
        self.velocity = min(max(velocity, 1), 127)
        self.channel = min(channel, 15)
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey { case tick, length, pitch, velocity, channel, muted }

    /// Projects from before notes could be muted have no `muted` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Tick.self, forKey: .tick)
        length = try c.decode(Tick.self, forKey: .length)
        // The same limits as the init: a file is input too.
        pitch = min(try c.decode(UInt8.self, forKey: .pitch), 127)
        velocity = min(max(try c.decode(UInt8.self, forKey: .velocity), 1), 127)
        channel = min(try c.decode(UInt8.self, forKey: .channel), 15)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// A MIDI message in a clip that is not a note: a controller (sustain, mod wheel), pitch bend, channel or
/// key pressure, a program change. Played at its tick like a note, recorded from the keyboard like one.
/// `status` carries the kind and the channel; `data1` and `data2` are the message bytes.
public struct MIDIControlEvent: Hashable, Codable, Sendable {
    /// Relative to the clip start.
    public var tick: Tick
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8
    /// A breakpoint of an envelope: the value moves in a straight line to the next event of the same kind
    /// (the player sends the steps in between). False: the value holds until the next event, like a recorded message.
    public var ramp: Bool

    public init(tick: Tick, status: UInt8, data1: UInt8, data2: UInt8, ramp: Bool = false) {
        self.tick = tick
        self.status = status
        self.data1 = min(data1, 127)
        self.data2 = min(data2, 127)
        self.ramp = ramp
    }

    private enum CodingKeys: String, CodingKey { case tick, status, data1, data2, ramp }

    /// Events from before envelopes had ramps have no `ramp` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Tick.self, forKey: .tick)
        status = try c.decode(UInt8.self, forKey: .status)
        data1 = min(try c.decode(UInt8.self, forKey: .data1), 127)
        data2 = min(try c.decode(UInt8.self, forKey: .data2), 127)
        ramp = try c.decodeIfPresent(Bool.self, forKey: .ramp) ?? false
    }

    /// A controller change on `channel`.
    public static func controller(_ number: UInt8, _ value: UInt8, tick: Tick, channel: UInt8 = 0, ramp: Bool = false) -> MIDIControlEvent {
        MIDIControlEvent(tick: tick, status: 0xB0 | (channel & 15), data1: number, data2: value, ramp: ramp)
    }

    /// A pitch bend of `amount` (-8192...8191, 0 is the centre) on `channel`.
    public static func pitchBend(_ amount: Int, tick: Tick, channel: UInt8 = 0, ramp: Bool = false) -> MIDIControlEvent {
        let v = UInt16(min(max(amount, -8192), 8191) + 8192)
        return MIDIControlEvent(tick: tick, status: 0xE0 | (channel & 15), data1: UInt8(v & 0x7F), data2: UInt8(v >> 7), ramp: ramp)
    }

    /// True when `other` is the same kind of control on the same channel: the same controller number, or
    /// both a bend, both a channel pressure, both a program change, the same key's pressure.
    public func sameKind(as other: MIDIControlEvent) -> Bool {
        guard status == other.status else { return false }
        return (kind == 0xB0 || kind == 0xA0) ? data1 == other.data1 : true
    }

    /// The value as one number: the bend's 14 bits (0...16383), else the 7-bit value.
    public var wideValue: Int { isPitchBend ? Int(data2) << 7 | Int(data1) : Int(value) }

    /// The same event with its value set from `wideValue`.
    public func with(wideValue v: Int) -> MIDIControlEvent {
        var e = self
        if isPitchBend {
            let w = min(max(v, 0), 16_383)
            e.data1 = UInt8(w & 0x7F); e.data2 = UInt8(w >> 7)
        } else if isController {
            e.data2 = UInt8(min(max(v, 0), 127))
        } else {
            e.data1 = UInt8(min(max(v, 0), 127))
        }
        return e
    }

    public var kind: UInt8 { status & 0xF0 }
    public var channel: UInt8 { status & 0x0F }
    public var isController: Bool { kind == 0xB0 }
    public var isPitchBend: Bool { kind == 0xE0 }
    public var isChannelPressure: Bool { kind == 0xD0 }
    /// The controller number of a controller change.
    public var controller: UInt8? { isController ? data1 : nil }
    /// The signed bend amount of a pitch bend, -8192...8191.
    public var bend: Int? { isPitchBend ? Int(data2) << 7 | Int(data1) - 8192 : nil }
    /// The value of the message, 0...127: a controller's value, the pressure, the program, or the bend's coarse byte.
    public var value: UInt8 { isController ? data2 : (isPitchBend ? data2 : data1) }

    /// The messages that are controls, from a MIDI status byte: not notes, not system messages.
    public static func isControl(status: UInt8) -> Bool {
        let kind = status & 0xF0
        return kind == 0xA0 || kind == 0xB0 || kind == 0xC0 || kind == 0xD0 || kind == 0xE0
    }
}

public struct MIDIClip: Hashable, Codable, Sendable, Identifiable {
    public var id: ClipID
    public var start: Tick
    public var length: Tick
    public var loop: Bool
    public var notes: [MIDINote]
    /// Controllers, pitch bend and pressure, sorted by tick. They loop with the clip like the notes.
    public var controls: [MIDIControlEvent]
    public var colorIndex: Int?
    public var name: String?
    /// Clip automation of the track's parameters, ticks from the clip start. `nil`: none. See `Clip.lanes`.
    public var lanes: [AutomationLane]?
    /// Length of one cycle of the clip automation. `nil`: linked to the clip length (it loops with the clip).
    /// Set, it runs on its own: a 16-bar curve over a 1-bar loop.
    public var automationLength: Tick?
    /// A timing and accent template the clip plays with. The notes stay; `playedNotes` has them moved.
    public var groove: GrooveSetting?

    public init(id: ClipID = ClipID(), start: Tick = 0, length: Tick, loop: Bool = false, notes: [MIDINote] = [], controls: [MIDIControlEvent] = []) {
        self.id = id
        self.start = start
        self.length = length
        self.loop = loop
        self.notes = notes
        self.controls = controls
    }

    private enum CodingKeys: String, CodingKey { case id, start, length, loop, notes, controls, colorIndex, name, lanes, automationLength, groove }

    /// Projects from before clips held controls have no `controls` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ClipID.self, forKey: .id)
        start = try c.decode(Tick.self, forKey: .start)
        length = try c.decode(Tick.self, forKey: .length)
        loop = try c.decode(Bool.self, forKey: .loop)
        notes = try c.decode([MIDINote].self, forKey: .notes)
        controls = try c.decodeIfPresent([MIDIControlEvent].self, forKey: .controls) ?? []
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        lanes = try c.decodeIfPresent([AutomationLane].self, forKey: .lanes)
        automationLength = try c.decodeIfPresent(Tick.self, forKey: .automationLength)
        groove = try c.decodeIfPresent(GrooveSetting.self, forKey: .groove)
    }

    /// The controls of one kind, in tick order: a controller number, or pitch bend (`controller` nil).
    public func controls(controller: UInt8?, channel: UInt8? = nil) -> [MIDIControlEvent] {
        controls.filter { ($0.controller == controller && (controller != nil || $0.isPitchBend)) && (channel == nil || $0.channel == channel) }
    }

    /// The controller numbers the clip holds, and whether it holds pitch bend.
    public var controlKinds: (controllers: [UInt8], pitchBend: Bool) {
        (Array(Set(controls.compactMap(\.controller))).sorted(), controls.contains { $0.isPitchBend })
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
    public var colorIndex: Int?

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

    /// Own length of the clip automation, `nil` when it is linked to the clip. A dummy clip is always linked.
    public var automationLength: Tick? {
        get {
            switch self {
            case .audio(let c): c.automationLength
            case .midi(let c): c.automationLength
            case .dummy: nil
            }
        }
        set {
            switch self {
            case .audio(var c): c.automationLength = newValue; self = .audio(c)
            case .midi(var c): c.automationLength = newValue; self = .midi(c)
            case .dummy: break
            }
        }
    }

    /// One cycle of the clip automation: its own length, or the clip length. The lanes repeat every cycle.
    public var automationCycle: Tick { max(1, automationLength ?? length) }

    /// The clip's own automation, ticks from the clip start. While the clip plays, a lane overrides the
    /// track lane of the same parameter. An audio or MIDI clip moves the parameters of its own track
    /// (mixer lanes use `ParameterAddress.ownTrack`); a dummy clip can move any parameter of the project.
    public var lanes: [AutomationLane] {
        get {
            switch self {
            case .audio(let c): c.lanes ?? []
            case .midi(let c): c.lanes ?? []
            case .dummy(let c): c.lanes
            }
        }
        set {
            switch self {
            case .audio(var c): c.lanes = newValue.isEmpty ? nil : newValue; self = .audio(c)
            case .midi(var c): c.lanes = newValue.isEmpty ? nil : newValue; self = .midi(c)
            case .dummy(var c): c.lanes = newValue; self = .dummy(c)
            }
        }
    }

    public var length: Tick {
        switch self {
        case .audio(let c): c.length
        case .midi(let c): c.length
        case .dummy(let c): c.length
        }
    }

    public var colorIndex: Int? {
        switch self {
        case .audio(let c): c.colorIndex
        case .midi(let c): c.colorIndex
        case .dummy(let c): c.colorIndex
        }
    }

    /// The clip's own name; empty for none.
    public var ownName: String {
        switch self {
        case .audio(let c): c.name ?? ""
        case .midi(let c): c.name ?? ""
        case .dummy(let c): c.name
        }
    }

    public func with(name: String) -> Clip {
        let value: String? = name.isEmpty ? nil : name
        switch self {
        case .audio(var c): c.name = value; return .audio(c)
        case .midi(var c): c.name = value; return .midi(c)
        case .dummy(var c): c.name = name; return .dummy(c)
        }
    }

    public func with(colorIndex: Int?) -> Clip {
        switch self {
        case .audio(var c): c.colorIndex = colorIndex; return .audio(c)
        case .midi(var c): c.colorIndex = colorIndex; return .midi(c)
        case .dummy(var c): c.colorIndex = colorIndex; return .dummy(c)
        }
    }

    /// The clip with its start moved to `newStart` and its end kept: the left edge trimmed or extended.
    /// The content stays where it was on the timeline: audio moves its offset, notes and clip automation
    /// move the other way. Notes cut by the new start are shortened; notes and points before it are dropped.
    /// `nil` when nothing would remain, or audio would start before its file. A looping audio clip with a
    /// `period` (its file length in ticks) wraps instead: the offset goes round the loop.
    public func trimmingStart(to newStart: Tick, period: Tick? = nil) -> Clip? {
        let end = start.rawValue + length.rawValue
        let d = newStart.rawValue - start.rawValue
        guard newStart.rawValue >= 0, newStart.rawValue < end else { return nil }
        func shift(_ lanes: [AutomationLane]) -> [AutomationLane] {
            lanes.map { lane in
                var l = lane
                l.points = lane.points.compactMap { p in
                    var p = p; p.tick = Tick(p.tick.rawValue - d); return p.tick.rawValue >= 0 ? p : nil
                }
                return l
            }.filter { !$0.points.isEmpty }
        }
        var clip = with(start: newStart, length: Tick(end - newStart.rawValue))
        switch clip {
        case .audio(var c):
            if let period, c.loop, c.ownLoop, period.rawValue > 0 {
                // A loop of its own: the start moves through the intro and round the loop, like playback.
                c.offset = c.playTick(after: Tick(d), session: false, fileTicks: period)
            } else if let period, c.loop, period.rawValue > 0 {
                let p = period.rawValue
                c.offset = Tick(((c.offset.rawValue + d) % p + p) % p)
            } else {
                guard c.offset.rawValue + d >= 0 else { return nil }
                c.offset = Tick(c.offset.rawValue + d)
            }
            c.lanes = c.lanes.map(shift)
            if let env = c.gainEnvelope {
                let moved = env.compactMap { p -> AutomationPoint? in
                    var p = p; p.tick = Tick(p.tick.rawValue - d); return p.tick.rawValue >= 0 ? p : nil
                }
                c.gainEnvelope = moved.isEmpty ? nil : moved
            }
            clip = .audio(c)
        case .midi(var c):
            c.notes = c.notes.compactMap { n in
                var n = n
                let s = n.tick.rawValue - d, e = s + n.length.rawValue
                guard e > 0 else { return nil }
                n.tick = Tick(max(0, s)); n.length = Tick(e - max(0, s))
                return n
            }
            c.lanes = c.lanes.map(shift)
            clip = .midi(c)
        case .dummy(var c):
            c.lanes = shift(c.lanes)
            clip = .dummy(c)
        }
        return clip
    }

    /// The same clip under a new ID.
    public func withNewID() -> Clip {
        switch self {
        case .audio(var c): c.id = ClipID(); return .audio(c)
        case .midi(var c): c.id = ClipID(); return .midi(c)
        case .dummy(var c): c.id = ClipID(); return .dummy(c)
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
/// One automatable parameter of a hosted plugin, as the plugin reported it when it loaded.
/// Kept in the project so automation keeps its names and ranges when the plugin is missing.
public struct PluginParam: Hashable, Codable, Sendable {
    /// "au.<address>" for an Audio Unit parameter.
    public var key: String
    public var name: String
    public var min: Double
    public var max: Double
    public var def: Double
    public var unit: String

    public init(key: String, name: String, min: Double, max: Double, def: Double, unit: String = "") {
        self.key = key
        self.name = name
        self.min = min
        self.max = max
        self.def = def
        self.unit = unit
    }
}

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
    /// Automatable parameters of a hosted plugin. `nil` until the plugin has loaded once.
    public var pluginParams: [PluginParam]?
    /// The track a sidechain effect (a compressor) listens to instead of its own input. `nil`: its own input.
    public var sidechain: TrackID?
    /// Where on that track the sidechain taps the sound. `nil`: after the mixer, the oldest behaviour.
    public var sidechainTap: SidechainTap?
    public var tap: SidechainTap { sidechainTap ?? .postMixer }
    /// The MIDI track whose notes an effect that listens to notes (the Resonator) takes. `nil`: its own track.
    public var midiFrom: TrackID?
    /// View state: the card is folded to its title. Saved with the project, like the arm state; no undo.
    public var folded: Bool?
    /// The chains and macros of a rack ("audiorack", "midirack"). `nil` for every other device. See `Rack`.
    public var rack: Rack?
    /// The text of a programmable device ("patch"). It compiles at load; see `PatchCompiler`.
    public var source: String?

    public init(id: DeviceID = DeviceID(), format: String, identifier: String, name: String,
                bypassed: Bool = false, state: Data? = nil, params: [String: Double] = [:], sidechain: TrackID? = nil,
                rack: Rack? = nil, source: String? = nil) {
        self.id = id
        self.format = format
        self.identifier = identifier
        self.name = name
        self.bypassed = bypassed
        self.state = state
        self.params = params
        self.sidechain = sidechain
        self.rack = rack
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, format, identifier, name, bypassed, state, params, pluginParams, sidechain, sidechainTap, midiFrom, folded, rack, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DeviceID.self, forKey: .id)
        format = try c.decode(String.self, forKey: .format)
        identifier = try c.decode(String.self, forKey: .identifier)
        name = try c.decode(String.self, forKey: .name)
        bypassed = try c.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        state = try c.decodeIfPresent(Data.self, forKey: .state)
        params = try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
        pluginParams = try c.decodeIfPresent([PluginParam].self, forKey: .pluginParams)
        sidechain = try c.decodeIfPresent(TrackID.self, forKey: .sidechain)
        sidechainTap = try c.decodeIfPresent(SidechainTap.self, forKey: .sidechainTap)
        midiFrom = try c.decodeIfPresent(TrackID.self, forKey: .midiFrom)
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded)
        rack = try c.decodeIfPresent(Rack.self, forKey: .rack)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        // A rack by identifier always has its chains, even from a file that left them out.
        if rack == nil, format == "builtin", identifier == "audiorack" || identifier == "midirack" { rack = Rack() }
    }
}

/// Where a sidechain taps its source track, as in Live: before the track's devices, after them, or after
/// its fader and pan (the track's output).
public enum SidechainTap: String, Codable, Sendable, CaseIterable, Hashable {
    case preFX, postFX, postMixer

    public var name: String {
        switch self {
        case .preFX: "Pre FX"
        case .postFX: "Post FX"
        case .postMixer: "Post Mixer"
        }
    }
}

public struct Send: Hashable, Codable, Sendable {
    public var target: TrackID
    public var levelDb: Double
    public var preFader: Bool
    /// The send is off for the moment; the level stays, so it comes back as it was.
    public var muted: Bool

    public init(target: TrackID, levelDb: Double = 0, preFader: Bool = false, muted: Bool = false) {
        self.target = target
        self.levelDb = levelDb
        self.preFader = preFader
        self.muted = muted
    }

    enum CodingKeys: String, CodingKey { case target, levelDb, preFader, muted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(TrackID.self, forKey: .target)
        levelDb = try c.decode(Double.self, forKey: .levelDb)
        preFader = try c.decodeIfPresent(Bool.self, forKey: .preFader) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// What a track lets through from its input (Live: Monitor In / Auto / Off).
/// Sound card input ("Ext. In"): `input` plays it always, in place of the clips; `auto` plays it while the
/// track is armed; `off` never. Another track as input: `input` and `auto` pass its sound, `off` mutes it.
public enum MonitorMode: String, Codable, Sendable, CaseIterable { case input, auto, off }

/// The input of an audio track (Live: "Audio From"). `external` is the sound card; `track` is another track after
/// its fader, or the master ("Resampling"); `noInput` is nothing. Tracks that send their output to this track
/// ("Audio To") feed it in every case.
public enum AudioSource: Hashable, Sendable {
    case external
    case track(TrackID)
    case noInput
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
    /// Audio tracks: take the sound of another track (after its fader) as input. Live: "Audio From" a track.
    /// Optional, so older project files still load.
    public var inputTrack: TrackID?
    /// Audio tracks: no input at all (Live: "No Input"). The track plays its clips and what other tracks send to
    /// it ("Audio To" this track); it records that fed sound, not the sound card. Wins over `inputTrack`.
    public var noInput: Bool?
    /// Audio tracks: the sound card channels to record. `nil` uses the channels of the audio settings.
    public var inputChannels: InputChannels?
    public var monitor: MonitorMode?
    /// No direct output; the track is heard only through its sends. Live: "Audio To: Sends Only".
    public var sendsOnly: Bool?
    /// Armed to record when the project was saved, so the arms come back with it. Not an edit: no undo.
    public var armed: Bool?
    /// The automation lanes open under the track in the arrangement when the project was saved, top to
    /// bottom, and whether they were folded away. View state, saved with the project. Not an edit: no undo.
    public var automationLanes: [ParameterAddress]?
    public var automationFolded: Bool?
    /// The session clip that played, or was ready to play, when the project was saved, so the next Play
    /// after a reopen starts it again. `keptStop`: the track was stopped in the session instead (silent).
    /// Not an edit: no undo.
    public var keptClip: ClipID?
    public var keptStop: Bool?
    /// MIDI tracks: a hardware destination that gets the notes. `nil` means none.
    public var midiOutput: MIDIOutputSelection?
    public var monitorMode: MonitorMode { monitor ?? .auto }
    public var isSendsOnly: Bool { sendsOnly ?? false }
    public var hasNoInput: Bool { noInput ?? false }
    /// What an audio track takes as input: the sound card, another track, or nothing. Only this decides; the
    /// stored fields are read through it.
    public var audioSource: AudioSource {
        if hasNoInput { return .noInput }
        return inputTrack.map { .track($0) } ?? .external
    }
    /// The tracks whose output is this track ("Audio To" it), in project order. They sum into its input.
    public func feeders(in project: Project) -> [Track] {
        project.tracks.filter { $0.output == id && !$0.isSendsOnly && $0.hardwareOutput == nil }
    }

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
    /// The musical length of an asset placed at `start`. A loop that will be warped to the project tempo
    /// keeps its own beats (four beats at 100 BPM stay four beats at 120 BPM); other audio keeps its seconds.
    public func naturalLength(of asset: Asset, from start: Tick = 0) -> Tick {
        let seconds = Double(asset.frames) / max(1, asset.sampleRate)
        if let bpm = asset.sourceTempo, bpm > 0, autoWarp(for: asset) != .off {
            return Tick(max(1, Tick.quarters(seconds * bpm / 60).rawValue))
        }
        let end = tempoMap.tick(atSeconds: tempoMap.seconds(at: start) + seconds)
        return Tick(max(1, (end - start).rawValue))
    }

    /// The warp mode a new clip of the asset gets. Audio with a known tempo follows the project tempo, like
    /// a warped clip in Live: a loop in Beats, a longer file (a song, a stem) in Complex. Without a tempo: off.
    public func autoWarp(for asset: Asset) -> WarpMode {
        guard let bpm = asset.sourceTempo, bpm > 0, asset.sampleRate > 0 else { return .off }
        return autoLoop.shouldLoop(seconds: Double(asset.frames) / asset.sampleRate) ? .beats : .complex
    }

    public func makeAudioClip(asset assetID: AssetID, start: Tick = 0, length: Tick) -> AudioClip {
        var loop = false
        var warp = WarpMode.off
        if let asset = asset(assetID), asset.sampleRate > 0 {
            loop = autoLoop.shouldLoop(seconds: Double(asset.frames) / asset.sampleRate)
            warp = autoWarp(for: asset)
        }
        return AudioClip(asset: assetID, start: start, length: length, loop: loop,
                         fadeInMs: defaultFadeMs, fadeOutMs: defaultFadeMs, warpMode: warp)
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

extension Project {
    /// Commands that make room on a track's arrangement from `start` to `end`, like a recording in Live:
    /// clips inside go, clips that overlap an edge are cut there, a clip around the range is split in two.
    public func clearing(track id: TrackID, from start: Tick, to end: Tick, except keep: ClipID? = nil) -> [Command] {
        guard let track = track(id), end > start else { return [] }
        var commands: [Command] = []
        for clip in track.clips where clip.id != keep {
            let s = clip.start, e = clip.start + clip.length
            guard s < end && e > start else { continue }
            if s >= start && e <= end {
                commands.append(.removeClip(clip: clip.id))
            } else if s < start && e > end {
                commands.append(.setClipRange(clip: clip.id, start: s, length: start - s))
                if let right = clip.trimmingStart(to: end)?.withNewID() { commands.append(.insertClip(track: id, clip: right)) }
            } else if s < start {
                commands.append(.setClipRange(clip: clip.id, start: s, length: start - s))
            } else if let right = clip.trimmingStart(to: end) {
                commands.append(.setClip(clip: right))
            } else {
                commands.append(.removeClip(clip: clip.id))
            }
        }
        return commands
    }
}
