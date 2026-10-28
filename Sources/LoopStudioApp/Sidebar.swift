import AppKit
import LoopStudioCore
import LoopStudioEngine
import SwiftUI

private let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac"]

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var units: [AudioUnitInfo] = []
    @State private var unitsLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            tabs
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            switch model.sidebarTab {
            case .audio: AudioBrowser(search: search)
            case .effects: UnitList(title: "Audio Effects", match: "effect", units: units, loaded: unitsLoaded, search: search, builtIn: BuiltInEffects.all)
            case .instruments: UnitList(title: "Instruments", match: "instrument", units: units, loaded: unitsLoaded, search: search, builtIn: [])
            case .projects: ProjectList()
            }
        }
        .task {
            guard !unitsLoaded else { return }
            units = await Task.detached { AudioUnitCatalog.list() }.value
            unitsLoaded = true
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button { model.sidebarTab = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon(tab)).font(.system(size: 15))
                        Text(title(tab)).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .foregroundStyle(model.sidebarTab == tab ? Theme.accent : Theme.dim)
                    .background(model.sidebarTab == tab ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }

    private func icon(_ t: SidebarTab) -> String {
        switch t {
        case .audio: "waveform"
        case .effects: "slider.horizontal.3"
        case .instruments: "pianokeys"
        case .projects: "folder"
        }
    }

    private func title(_ t: SidebarTab) -> String {
        switch t {
        case .audio: "Audio"
        case .effects: "Effects"
        case .instruments: "Instruments"
        case .projects: "Projects"
        }
    }
}

// MARK: Audio files

struct AudioBrowser: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var library: [URL] = []

    var body: some View {
        List {
            Section("Project Audio") {
                let assets = model.project.assets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if assets.isEmpty { Text("Nothing imported yet").foregroundStyle(Theme.dim) }
                ForEach(assets, id: \.id) { asset in
                    if let url = model.assetURL(asset) { FileRow(url: url, title: asset.name, detail: duration(asset)) }
                }
            }
            Section("Demo Samples") {
                ForEach(filtered(library), id: \.self) { FileRow(url: $0, title: $0.deletingPathExtension().lastPathComponent, detail: nil) }
            }
            Section {
                ForEach(model.audioFolders, id: \.self) { folder in
                    DisclosureGroup {
                        ForEach(filtered(files(in: folder)), id: \.self) {
                            FileRow(url: $0, title: $0.deletingPathExtension().lastPathComponent, detail: nil)
                        }
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .contextMenu { Button("Remove from list") { model.removeAudioFolder(folder) } }
                    }
                }
                Button { addFolder() } label: { Label("Add Folder…", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            } header: { Text("Places") }
        }
        .listStyle(.sidebar)
        .onAppear { library = DemoSamples.ensure() }
    }

    private func filtered(_ urls: [URL]) -> [URL] {
        search.isEmpty ? urls : urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    private func duration(_ a: Asset) -> String {
        let s = Double(a.frames) / max(1, a.sampleRate)
        return s < 10 ? String(format: "%.1f s", s) : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func files(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in e where audioExtensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
            if result.count >= 1_500 { break }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach { model.addAudioFolder($0) } }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.previewing == url ? "stop.fill" : "play.fill")
                .font(.system(size: 9)).foregroundStyle(model.previewing == url ? Theme.accent : Theme.dim)
                .frame(width: 14)
            Text(title).lineLimit(1)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(Theme.dim) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.togglePreview(url) }
        .draggable(url)
        .help("Click to listen. Drag onto a clip slot or the timeline.")
    }
}

// MARK: Effects and instruments

struct UnitList: View {
    @Environment(AppModel.self) private var model
    let title: String
    let match: String
    let units: [AudioUnitInfo]
    let loaded: Bool
    let search: String
    let builtIn: [EffectSpec]

    var body: some View {
        List {
            if !builtIn.isEmpty {
                Section("LoopStudio") {
                    ForEach(builtIn.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { spec in
                        Label(spec.name, systemImage: "slider.horizontal.3")
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.addEffect(spec.id) }
                            .draggable("fx:\(spec.id)")
                            .help("Double-click to add to the selected track, or drag it onto a track.")
                    }
                }
            }
            Section("Audio Units") {
                if !loaded { ProgressView().controlSize(.small) }
                let shown = units.filter { $0.kind.localizedCaseInsensitiveContains(match) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, unit in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(unit.name).lineLimit(1)
                        Text(unit.manufacturer).font(.caption).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.addAudioUnit(identifier: unit.identifier, name: unit.name) }
                    .draggable("au:\(unit.identifier)|\(unit.name)")
                    .help("Double-click to add. Drag onto a track.")
                }
                if loaded && shown.isEmpty { Text("None found").foregroundStyle(Theme.dim) }
            }
            Section {
                Text("Double-click a plugin to add it, or drag it onto a track. An instrument creates a MIDI track.").font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: Projects

struct ProjectList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                Button { model.newProject() } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            Section("Projects") {
                ForEach(model.projectPackages(), id: \.self) { url in
                    HStack {
                        Image(systemName: url == model.packageURL ? "folder.fill" : "folder")
                            .foregroundStyle(url == model.packageURL ? Theme.accent : Theme.dim)
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(url) }
                    .help("Double-click to open")
                }
            }
            Section {
                Text(AppModel.projectsFolder.path).font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .listStyle(.sidebar)
    }
}
