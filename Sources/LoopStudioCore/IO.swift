import Foundation

// Hardware I/O, in two layers.
//
// 1. The PROJECT has logical ports ("Main", "Cue", "Input 1-2"). Tracks point at ports.
// 2. The MACHINE has a profile: which sound card, and which physical channels each port uses.
//
// So a project made on a studio interface opens on a laptop with built-in speakers: the ports stay,
// only the profile differs. `IOResolver` turns (profile + ports + connected devices) into a plan
// and a list of issues. It is pure logic, so tests need no sound card.

public enum PortDirection: String, Codable, Sendable { case input, output }

public struct IOPort: Hashable, Codable, Sendable, Identifiable {
    public var id: PortID
    public var name: String
    public var direction: PortDirection
    /// 1 = mono, 2 = stereo, more for surround or multi-out.
    public var channels: Int

    public init(id: PortID = PortID(), name: String, direction: PortDirection, channels: Int) {
        self.id = id
        self.name = name
        self.direction = direction
        self.channels = channels
    }
}

// MARK: Devices (data only; the Engine fills it from Core Audio and CoreMIDI)

public struct DeviceChannel: Hashable, Codable, Sendable {
    /// 0-based position on the device.
    public var index: Int
    public var name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

public struct AudioDeviceInfo: Hashable, Codable, Sendable, Identifiable {
    /// Stable across restarts and re-plugging. Use this to remember a device, never the numeric ID.
    public var uid: String
    public var name: String
    public var manufacturer: String
    /// "built-in", "usb", "bluetooth", "airplay", "aggregate", "virtual", "thunderbolt", "other"
    public var transport: String
    public var inputs: [DeviceChannel]
    public var outputs: [DeviceChannel]
    public var sampleRates: [Double]
    public var bufferMin: Int
    public var bufferMax: Int
    public var inputLatencyFrames: Int
    public var outputLatencyFrames: Int

    public var id: String { uid }

    public init(uid: String, name: String, manufacturer: String = "", transport: String = "other",
                inputs: [DeviceChannel] = [], outputs: [DeviceChannel] = [], sampleRates: [Double] = [],
                bufferMin: Int = 16, bufferMax: Int = 4096,
                inputLatencyFrames: Int = 0, outputLatencyFrames: Int = 0) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.inputs = inputs
        self.outputs = outputs
        self.sampleRates = sampleRates
        self.bufferMin = bufferMin
        self.bufferMax = bufferMax
        self.inputLatencyFrames = inputLatencyFrames
        self.outputLatencyFrames = outputLatencyFrames
    }
}

public struct MIDIEndpointInfo: Hashable, Codable, Sendable, Identifiable {
    /// CoreMIDI unique ID. Stable across restarts; the right key to remember a device.
    public var uniqueID: Int32
    public var name: String
    public var manufacturer: String
    public var model: String
    public var isOffline: Bool

    public var id: Int32 { uniqueID }

    public init(uniqueID: Int32, name: String, manufacturer: String = "", model: String = "", isOffline: Bool = false) {
        self.uniqueID = uniqueID
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.isOffline = isOffline
    }
}

// MARK: MIDI input selection

public struct MIDIInputSelection: Hashable, Codable, Sendable {
    /// CoreMIDI unique ID of the source. `nil` listens to every online source.
    public var sourceUID: Int32?
    /// The device name when it was chosen. Shown when the device is not connected.
    public var sourceName: String?
    /// 0 to 15. `nil` listens to all channels.
    public var channel: UInt8?

    public init(sourceUID: Int32? = nil, sourceName: String? = nil, channel: UInt8? = nil) {
        self.sourceUID = sourceUID
        self.sourceName = sourceName
        self.channel = channel.map { min($0, 15) }
    }
}

public enum MIDIInputIssue: Hashable, Sendable {
    case sourceMissing(uniqueID: Int32, name: String?)
    case sourceOffline(uniqueID: Int32, name: String?)
}

public struct ResolvedMIDIInput: Hashable, Sendable {
    public var sources: [Int32]
    public var channel: UInt8?
    public var issue: MIDIInputIssue?
}

public enum MIDIResolver {
    /// A chosen device that is gone gives NO input and an issue. It never falls back to "all sources":
    /// that would let the wrong keyboard play the wrong instrument.
    public static func resolve(_ selection: MIDIInputSelection, available: [MIDIEndpointInfo]) -> ResolvedMIDIInput {
        guard let uid = selection.sourceUID else {
            return ResolvedMIDIInput(sources: available.filter { !$0.isOffline }.map(\.uniqueID).sorted(),
                                     channel: selection.channel, issue: nil)
        }
        guard let endpoint = available.first(where: { $0.uniqueID == uid }) else {
            return ResolvedMIDIInput(sources: [], channel: selection.channel,
                                     issue: .sourceMissing(uniqueID: uid, name: selection.sourceName))
        }
        if endpoint.isOffline {
            return ResolvedMIDIInput(sources: [], channel: selection.channel,
                                     issue: .sourceOffline(uniqueID: uid, name: selection.sourceName))
        }
        return ResolvedMIDIInput(sources: [uid], channel: selection.channel, issue: nil)
    }
}

// MARK: Audio profile and resolver

public struct PortMapping: Hashable, Codable, Sendable {
    public var port: PortID
    /// One physical channel (0-based) for each channel of the port.
    public var channels: [Int]

    public init(port: PortID, channels: [Int]) {
        self.port = port
        self.channels = channels
    }
}

/// Machine-level settings. Stored per Mac, not in the project.
public struct AudioIOProfile: Hashable, Codable, Sendable {
    /// `nil` means the system default device.
    public var outputDeviceUID: String?
    public var inputDeviceUID: String?
    public var sampleRate: Double
    public var bufferFrames: Int
    public var outputs: [PortMapping]
    public var inputs: [PortMapping]

    public init(outputDeviceUID: String? = nil, inputDeviceUID: String? = nil, sampleRate: Double = 48_000,
                bufferFrames: Int = 256, outputs: [PortMapping] = [], inputs: [PortMapping] = []) {
        self.outputDeviceUID = outputDeviceUID
        self.inputDeviceUID = inputDeviceUID
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.outputs = outputs
        self.inputs = inputs
    }
}

public enum IOIssue: Hashable, Sendable {
    /// The chosen device is not connected. The default device is used.
    case deviceMissing(uid: String)
    /// No device with channels in this direction exists.
    case noDevice(PortDirection)
    case channelOutOfRange(port: PortID, channel: Int, available: Int)
    case widthMismatch(port: PortID, expected: Int, got: Int)
    /// The saved mapping was not valid. Free channels were assigned instead.
    case autoMapped(port: PortID)
    /// A used port has no channels left. It is silent.
    case unmapped(port: PortID)
    /// The device has one channel; a wider port plays on it.
    case foldedToMono(port: PortID)
    /// Two output ports share a channel. Their signals add up.
    case sharedChannel(channel: Int, ports: [PortID])
    case sampleRateChanged(requested: Double, using: Double)
    case bufferChanged(requested: Int, using: Int)
    /// The input device cannot run at the output device's rate. The engine needs an aggregate device.
    case inputRateMismatch(uid: String, rate: Double)
}

public struct ResolvedIO: Hashable, Sendable {
    public var outputDevice: AudioDeviceInfo?
    public var inputDevice: AudioDeviceInfo?
    public var sampleRate: Double
    public var bufferFrames: Int
    /// For each logical port, the physical channels it uses.
    public var outputs: [PortID: [Int]]
    public var inputs: [PortID: [Int]]
    public var issues: [IOIssue]
}

public enum IOResolver {
    public static func resolve(profile: AudioIOProfile, ports: [IOPort], used: Set<PortID>,
                               devices: [AudioDeviceInfo],
                               defaultOutputUID: String?, defaultInputUID: String?) -> ResolvedIO {
        var issues: [IOIssue] = []
        let outPorts = ports.filter { $0.direction == .output }
        let inPorts = ports.filter { $0.direction == .input }

        func pick(_ uid: String?, fallback: String?, direction: PortDirection, needed: Bool) -> AudioDeviceInfo? {
            func channels(_ d: AudioDeviceInfo) -> Int { direction == .output ? d.outputs.count : d.inputs.count }
            if let uid {
                if let d = devices.first(where: { $0.uid == uid && channels($0) > 0 }) { return d }
                issues.append(.deviceMissing(uid: uid))
            }
            if let fb = fallback, let d = devices.first(where: { $0.uid == fb && channels($0) > 0 }) { return d }
            if let d = devices.first(where: { channels($0) > 0 }) { return d }
            if needed { issues.append(.noDevice(direction)) }
            return nil
        }

        let outDevice = pick(profile.outputDeviceUID, fallback: defaultOutputUID, direction: .output, needed: !outPorts.isEmpty)
        let inDevice = profile.inputDeviceUID == nil && used.isDisjoint(with: Set(inPorts.map(\.id)))
            ? nil
            : pick(profile.inputDeviceUID, fallback: defaultInputUID, direction: .input, needed: !inPorts.isEmpty)

        // Sample rate and buffer size follow the output device (or the input device when there is no output).
        let primary = outDevice ?? inDevice
        var rate = profile.sampleRate
        if let rates = primary?.sampleRates, !rates.isEmpty, !rates.contains(rate) {
            let nearest = rates.min { (abs($0 - rate), -$0) < (abs($1 - rate), -$1) }!
            issues.append(.sampleRateChanged(requested: rate, using: nearest))
            rate = nearest
        }
        if let inDevice, inDevice.uid != primary?.uid, !inDevice.sampleRates.isEmpty, !inDevice.sampleRates.contains(rate) {
            issues.append(.inputRateMismatch(uid: inDevice.uid, rate: rate))
        }
        var buffer = profile.bufferFrames
        if let primary {
            var lo = primary.bufferMin, hi = primary.bufferMax
            if let inDevice, inDevice.uid != primary.uid { lo = max(lo, inDevice.bufferMin); hi = min(hi, inDevice.bufferMax) }
            if lo <= hi { buffer = min(max(buffer, lo), hi) }
            if buffer != profile.bufferFrames { issues.append(.bufferChanged(requested: profile.bufferFrames, using: buffer)) }
        }

        let outputs = map(outPorts, requested: profile.outputs, channelCount: outDevice?.outputs.count ?? 0,
                          used: used, issues: &issues)
        let inputs = map(inPorts, requested: profile.inputs, channelCount: inDevice?.inputs.count ?? 0,
                         used: used, issues: &issues)

        // Output ports that share a channel add up. Allowed, but worth a warning.
        var byChannel: [Int: [PortID]] = [:]
        for port in outPorts { for ch in Set(outputs[port.id] ?? []) { byChannel[ch, default: []].append(port.id) } }
        for (channel, owners) in byChannel.sorted(by: { $0.key < $1.key }) where owners.count > 1 {
            // Folding one wide port onto one channel is already reported as foldedToMono.
            issues.append(.sharedChannel(channel: channel, ports: owners))
        }

        return ResolvedIO(outputDevice: outDevice, inputDevice: inDevice, sampleRate: rate, bufferFrames: buffer,
                          outputs: outputs, inputs: inputs, issues: issues)
    }

    private static func map(_ ports: [IOPort], requested: [PortMapping], channelCount: Int,
                            used: Set<PortID>, issues: inout [IOIssue]) -> [PortID: [Int]] {
        var result: [PortID: [Int]] = [:]
        var taken = Set<Int>()
        var needsAuto: [(IOPort, hadMapping: Bool)] = []

        for port in ports {
            guard let request = requested.first(where: { $0.port == port.id }) else {
                needsAuto.append((port, false))
                continue
            }
            if request.channels.count != port.channels {
                issues.append(.widthMismatch(port: port.id, expected: port.channels, got: request.channels.count))
                needsAuto.append((port, true))
            } else if let bad = request.channels.first(where: { $0 < 0 || $0 >= channelCount }) {
                issues.append(.channelOutOfRange(port: port.id, channel: bad, available: channelCount))
                needsAuto.append((port, true))
            } else {
                result[port.id] = request.channels
                taken.formUnion(request.channels)
            }
        }

        for (port, hadMapping) in needsAuto {
            let free = (0..<channelCount).filter { !taken.contains($0) }
            if free.count >= port.channels {
                let channels = Array(free.prefix(port.channels))
                result[port.id] = channels
                taken.formUnion(channels)
                if hadMapping { issues.append(.autoMapped(port: port.id)) }
            } else if channelCount == 1 {
                result[port.id] = Array(repeating: 0, count: port.channels)
                if used.contains(port.id) && port.channels > 1 { issues.append(.foldedToMono(port: port.id)) }
            } else if used.contains(port.id) {
                issues.append(.unmapped(port: port.id))
            }
        }
        return result
    }
}
