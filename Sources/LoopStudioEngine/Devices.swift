import AVFoundation

/// An Audio Unit found on this Mac (instrument, effect, or MIDI processor).
public struct AudioUnitInfo: Sendable {
    public let name: String
    public let manufacturer: String
    public let kind: String
    /// "type/subtype/manufacturer", four characters each. Stored in the project to find the plugin again.
    public let identifier: String
    public var isInstrument: Bool { identifier.hasPrefix("aumu") }
    public var isEffect: Bool { identifier.hasPrefix("aufx") || identifier.hasPrefix("aumf") }
}

func fourCCString(_ code: FourCharCode) -> String {
    String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .macOSRoman) ?? "????"
}

public enum AudioUnitCatalog {
    public static func list() -> [AudioUnitInfo] {
        let any = AudioComponentDescription(componentType: 0, componentSubType: 0,
                                            componentManufacturer: 0, componentFlags: 0,
                                            componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: any).map {
            let d = $0.audioComponentDescription
            return AudioUnitInfo(name: $0.name, manufacturer: $0.manufacturerName, kind: $0.typeName,
                                 identifier: "\(fourCCString(d.componentType))/\(fourCCString(d.componentSubType))/\(fourCCString(d.componentManufacturer))")
        }
    }
}
