import CoreAudio
import CoreMIDI
import Foundation
import LoopStudioCore

/// Thin wrappers over the Core Audio property API.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, as _: T.Type, zero: T) -> T? {
        var address = address(selector, scope: scope, element: element)
        var result = zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var address = address(selector, scope: scope, element: element)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as _: T.Type, zero: T) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return items
    }

    /// Total channel count of a device in one direction.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public enum AudioDeviceCatalog {
    private static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000,
                                                  88_200, 96_000, 176_400, 192_000]

    /// All visible audio devices that have at least one channel.
    public static func devices() -> [AudioDeviceInfo] {
        HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, as: AudioObjectID.self, zero: 0)
            .compactMap(info)
            .sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }
    }

    public static func defaultOutputUID() -> String? { defaultUID(kAudioHardwarePropertyDefaultOutputDevice) }
    public static func defaultInputUID() -> String? { defaultUID(kAudioHardwarePropertyDefaultInputDevice) }

    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        guard let id = HAL.value(AudioObjectID(kAudioObjectSystemObject), selector, as: AudioObjectID.self, zero: 0), id != 0 else { return nil }
        return HAL.string(id, kAudioDevicePropertyDeviceUID)
    }

    static func info(_ id: AudioObjectID) -> AudioDeviceInfo? {
        if HAL.value(id, kAudioDevicePropertyIsHidden, as: UInt32.self, zero: 0) == 1 { return nil }
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let inCount = HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput)
        let outCount = HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        guard inCount + outCount > 0 else { return nil }

        func channels(_ count: Int, scope: AudioObjectPropertyScope, fallback: String) -> [DeviceChannel] {
            (0..<count).map { i in
                let name = HAL.string(id, kAudioObjectPropertyElementName, scope: scope, element: AudioObjectPropertyElement(i + 1))
                return DeviceChannel(index: i, name: (name?.isEmpty == false ? name : nil) ?? "\(fallback) \(i + 1)")
            }
        }

        let ranges = HAL.array(id, kAudioDevicePropertyAvailableNominalSampleRates, as: AudioValueRange.self,
                               zero: AudioValueRange(mMinimum: 0, mMaximum: 0))
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else { standardRates.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { rates.insert($0) } }
        }
        let buffer = HAL.value(id, kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self,
                               zero: AudioValueRange(mMinimum: 0, mMaximum: 0))

        func latency(_ scope: AudioObjectPropertyScope) -> Int {
            let device = HAL.value(id, kAudioDevicePropertyLatency, scope: scope, as: UInt32.self, zero: 0) ?? 0
            let safety = HAL.value(id, kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self, zero: 0) ?? 0
            return Int(device + safety)
        }

        return AudioDeviceInfo(
            uid: uid,
            name: HAL.string(id, kAudioObjectPropertyName) ?? uid,
            manufacturer: HAL.string(id, kAudioObjectPropertyManufacturer) ?? "",
            transport: transportName(HAL.value(id, kAudioDevicePropertyTransportType, as: UInt32.self, zero: 0) ?? 0),
            inputs: channels(inCount, scope: kAudioObjectPropertyScopeInput, fallback: "Input"),
            outputs: channels(outCount, scope: kAudioObjectPropertyScopeOutput, fallback: "Output"),
            sampleRates: rates.sorted(),
            bufferMin: Int(buffer?.mMinimum ?? 16) > 0 ? Int(buffer?.mMinimum ?? 16) : 16,
            bufferMax: Int(buffer?.mMaximum ?? 4096) > 0 ? Int(buffer?.mMaximum ?? 4096) : 4096,
            inputLatencyFrames: latency(kAudioObjectPropertyScopeInput),
            outputLatencyFrames: latency(kAudioObjectPropertyScopeOutput))
    }

    private static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
        case kAudioDeviceTransportTypeFireWire: "firewire"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypePCI: "pci"
        default: "other"
        }
    }
}

public enum MIDIEndpointCatalog {
    public static func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { info(MIDIGetSource($0)) }
    }

    public static func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { info(MIDIGetDestination($0)) }
    }

    private static func info(_ endpoint: MIDIEndpointRef) -> MIDIEndpointInfo? {
        guard endpoint != 0 else { return nil }
        func string(_ key: CFString) -> String {
            var value: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, key, &value) == noErr else { return "" }
            return (value?.takeRetainedValue() as String?) ?? ""
        }
        func integer(_ key: CFString) -> Int32 {
            var value: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, key, &value)
            return value
        }
        return MIDIEndpointInfo(uniqueID: integer(kMIDIPropertyUniqueID), name: string(kMIDIPropertyDisplayName),
                                manufacturer: string(kMIDIPropertyManufacturer), model: string(kMIDIPropertyModel),
                                isOffline: integer(kMIDIPropertyOffline) != 0)
    }
}

/// Calls `onChange` when sound cards or MIDI devices appear or disappear, or when the default device changes.
/// The callback arrives on a private queue. Keep it short: set a flag or post to your own actor.
public final class DeviceChangeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "loopstudio.device-monitor")
    private var audioListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var midiClient: MIDIClientRef = 0

    public init(onChange: @escaping @Sendable () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var address = HAL.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr {
                audioListeners.append((address, block))
            }
        }
        MIDIClientCreateWithBlock("loopstudio" as CFString, &midiClient) { notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged: onChange()
            default: break
            }
        }
    }

    deinit {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
        }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }
}
