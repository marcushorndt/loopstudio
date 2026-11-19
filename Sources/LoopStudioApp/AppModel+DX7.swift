import AppKit
import LoopStudioCore
import UniformTypeIdentifiers

/// One 32-voice bank file in the DX7 library: its name, its voice names, and the bytes to read a voice from.
struct DX7BankEntry: Identifiable, Hashable, Sendable {
    var url: URL
    /// The file's path under the library folder, without the extension: "rom/ROM1A".
    var name: String
    var names: [String]
    var data: Data
    var id: URL { url }

    func voice(_ i: Int) -> DX7.Voice? { DX7.Bank.voice(i, of: data) }
}

enum DX7LibraryState: Equatable {
    case idle, loading, loaded
}

/// The DX7 library: a folder of `.syx` banks under Application Support. The panel's browser searches
/// every voice of every bank by name; a pick writes the voice's 145 values onto the device in one undo step.
extension AppModel {
    /// `~/Library/Application Support/LoopStudio/DX7 Banks`.
    static var dx7Folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LoopStudio", isDirectory: true).appendingPathComponent("DX7 Banks", isDirectory: true)
    }

    /// Reads every bank once, off the main thread. The panel calls it when it appears.
    func loadDX7Library(force: Bool = false) {
        guard force || dx7LibraryState == .idle else { return }
        dx7LibraryState = .loading
        let folder = Self.dx7Folder
        Task.detached(priority: .utility) {
            let banks = Self.scanDX7Banks(folder)
            await MainActor.run {
                self.dx7Banks = banks
                self.dx7LibraryState = .loaded
            }
        }
    }

    nonisolated static func scanDX7Banks(_ folder: URL) -> [DX7BankEntry] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var banks: [DX7BankEntry] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in files where url.pathExtension.lowercased() == "syx" {
            guard let data = try? Data(contentsOf: url), let names = DX7.Bank.names(of: data) else { continue }
            var name = url.standardizedFileURL.deletingPathExtension().path
            if name.hasPrefix(base) { name = String(name.dropFirst(base.count)) }
            if name.hasPrefix("/") { name.removeFirst() }
            banks.append(DX7BankEntry(url: url, name: name, names: names, data: data))
        }
        return banks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Puts a voice onto a DX7 device: every voice parameter, the device's name, one undo step. The volume
    /// and the mappings stay.
    func loadDX7Voice(_ voice: DX7.Voice, onto id: DeviceID, on trackID: TrackID) {
        guard let track = project.track(trackID), var slot = track.device(id), slot.identifier == "dx7" else { return }
        for (key, value) in voice.params { slot.params[key] = value }
        slot.name = voice.name.isEmpty ? "DX7" : voice.name
        let chain = track.chainHolding(id)
        var list = siblings(of: id, on: track)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i] = slot
        apply(.setDevices(track: trackID, chain: chain?.id, devices: list), key: "dx7voice\(id)")
        status = "DX7: \(voice.name)"
    }

    /// The INIT VOICE: operator 1 alone.
    func initDX7Voice(onto id: DeviceID, on track: TrackID) {
        loadDX7Voice(DX7.Voice(name: "INIT VOICE", params: DX7.initVoice), onto: id, on: track)
    }

    /// "Import Banks…": copies `.syx` files (or folders of them) into the library and reads it again.
    func importDX7Banks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "syx") ?? .data]
        panel.message = "DX7 banks: 32-voice SysEx files (.syx)"
        guard panel.runModal() == .OK else { return }
        let fm = FileManager.default
        let folder = Self.dx7Folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0, skipped = 0
        for url in panel.urls {
            var files: [URL] = []
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let f as URL in e where f.pathExtension.lowercased() == "syx" { files.append(f) }
                }
            } else {
                files = [url]
            }
            for file in files {
                guard let data = try? Data(contentsOf: file), DX7.Bank.names(of: data) != nil else { skipped += 1; continue }
                var target = folder.appendingPathComponent(file.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " \(n)").appendingPathExtension("syx")
                    n += 1
                }
                if (try? fm.copyItem(at: file, to: target)) != nil { count += 1 } else { skipped += 1 }
            }
        }
        status = "Imported \(count) DX7 bank\(count == 1 ? "" : "s")" + (skipped > 0 ? ", skipped \(skipped) that are not 32-voice dumps" : "")
        loadDX7Library(force: true)
    }

    /// Writes the device's voice as a one-voice bank, so another DX7 or Dexed can read it.
    func exportDX7Voice(_ device: DeviceSlot) {
        let voice = DX7.Voice(name: device.name, params: device.params)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "syx") ?? .data]
        panel.nameFieldStringValue = PresetLibrary.safe(device.name) + ".syx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DX7.Bank(voices: [voice]).data.write(to: url)
            status = "Wrote \(url.lastPathComponent)"
        } catch {
            status = "Could not write the bank: \(error.localizedDescription)"
        }
    }
}
