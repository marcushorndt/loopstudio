import Foundation

/// A device saved on its own, to load again in any project: a built-in effect's parameters, a plugin's
/// state, or a whole rack with its chains and macros. Live calls this a preset (.adv, .adg). The file is
/// JSON with the extension `lspreset`; the library keeps one folder per device kind.
public struct DevicePreset: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let fileExtension = "lspreset"

    public var version: Int
    public var name: String
    public var device: DeviceSlot

    /// Takes the device as it is. What belongs to the project and not to the device goes: the sidechain
    /// source (a track) and the fold state. The IDs stay; `makeSlot` renews them.
    public init(name: String, device: DeviceSlot) {
        version = Self.currentVersion
        self.name = name
        var d = device
        d.sidechain = nil
        d.sidechainTap = nil
        d.folded = nil
        d.bypassed = false
        self.device = d
    }

    /// The device for a project: fresh IDs for it and everything inside, and the preset's name on it.
    public func makeSlot() -> DeviceSlot {
        var map: [UUID: UUID] = [:]
        var slot = device.withFreshIDs(map: &map)
        slot.name = name
        return slot
    }

    /// The preset's settings onto an existing device: the ID and the bypass stay, so automation,
    /// mappings and the engine instance stay with it. A rack's chains come in under fresh IDs.
    public func applied(to existing: DeviceSlot) -> DeviceSlot {
        var slot = makeSlot()
        slot.id = existing.id
        slot.bypassed = existing.bypassed
        slot.sidechain = existing.sidechain
        slot.sidechainTap = existing.sidechainTap
        slot.folded = existing.folded
        return slot
    }

    public static func read(_ url: URL) throws -> DevicePreset {
        let preset = try JSONDecoder().decode(DevicePreset.self, from: Data(contentsOf: url))
        guard preset.version <= currentVersion else { throw PresetError.newerVersion(preset.version) }
        return preset
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum PresetError: Error, Equatable, CustomStringConvertible {
    case newerVersion(Int)
    case wrongDevice(expected: String, found: String)

    public var description: String {
        switch self {
        case .newerVersion(let v): "The preset is from a newer LoopStudio (format \(v))."
        case .wrongDevice(let expected, let found): "The preset is for another device (\(found), not \(expected))."
        }
    }
}

/// One preset on disk, as the library lists it.
public struct PresetEntry: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var format: String
    public var identifier: String
    /// The name of the device the preset was saved from (a plugin's name, a rack's).
    public var deviceName: String
    public var id: URL { url }

    public init(url: URL, name: String, format: String, identifier: String, deviceName: String) {
        self.url = url; self.name = name; self.format = format; self.identifier = identifier; self.deviceName = deviceName
    }
}

/// The folder of presets: one subfolder per device kind, one file per preset.
public struct PresetLibrary: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/LoopStudio/Presets`.
    public static var standard: PresetLibrary {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PresetLibrary(root: support.appendingPathComponent("LoopStudio", isDirectory: true).appendingPathComponent("Presets", isDirectory: true))
    }

    /// The folder for a device kind. An Audio Unit identifier holds slashes; they become dashes.
    public func folder(for identifier: String) -> URL {
        root.appendingPathComponent(Self.safe(identifier), isDirectory: true)
    }

    /// The file a preset of this name and device kind gets.
    public func url(for name: String, identifier: String) -> URL {
        folder(for: identifier).appendingPathComponent(Self.safe(name)).appendingPathExtension(DevicePreset.fileExtension)
    }

    /// A file name without path separators or colons; empty becomes "Preset".
    public static func safe(_ name: String) -> String {
        let cleaned = name.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Preset" : trimmed
    }

    /// Writes the preset into its folder and returns the file. A preset of the same name is replaced.
    @discardableResult
    public func save(_ preset: DevicePreset) throws -> URL {
        let url = url(for: preset.name, identifier: preset.device.identifier)
        try preset.write(to: url)
        return url
    }

    /// Copies a preset file into the library under the preset's own name and device kind.
    @discardableResult
    public func importFile(_ url: URL) throws -> (entry: PresetEntry, preset: DevicePreset) {
        let preset = try DevicePreset.read(url)
        let target = try save(preset)
        return (PresetEntry(url: target, name: preset.name, format: preset.device.format,
                            identifier: preset.device.identifier, deviceName: preset.device.name), preset)
    }

    public func delete(_ entry: PresetEntry) throws {
        try FileManager.default.removeItem(at: entry.url)
    }

    /// Every preset in the library, read from disk, sorted by device then by name. A file that does not
    /// parse is skipped.
    public func list() -> [PresetEntry] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var entries: [PresetEntry] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == DevicePreset.fileExtension {
                guard let preset = try? DevicePreset.read(file) else { continue }
                entries.append(PresetEntry(url: file, name: preset.name, format: preset.device.format,
                                           identifier: preset.device.identifier, deviceName: preset.device.name))
            }
        }
        return entries.sorted {
            if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
