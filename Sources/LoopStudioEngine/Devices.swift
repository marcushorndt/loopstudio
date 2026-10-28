import AVFoundation
import CoreMIDI

/// An Audio Unit found on this Mac (instrument, effect, or MIDI processor).
public struct AudioUnitInfo: Sendable {
    public let name: String
    public let manufacturer: String
    public let kind: String
}

public enum AudioUnitCatalog {
    public static func list() -> [AudioUnitInfo] {
        let any = AudioComponentDescription(componentType: 0, componentSubType: 0,
                                            componentManufacturer: 0, componentFlags: 0,
                                            componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: any).map {
            AudioUnitInfo(name: $0.name, manufacturer: $0.manufacturerName, kind: $0.typeName)
        }
    }
}

public enum MIDIDevices {
    /// Names of all connected MIDI input sources.
    public static func inputNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { index in
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(index), kMIDIPropertyDisplayName, &name)
            return (name?.takeRetainedValue() as String?) ?? "Source \(index)"
        }
    }
}
