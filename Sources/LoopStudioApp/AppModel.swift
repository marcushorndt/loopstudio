import AVFoundation
import Foundation
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject
import Observation

enum ViewMode: String { case session, arrangement }
enum SidebarTab: String, CaseIterable { case audio, effects, instruments, projects }

enum SlotState {
    case empty
    case stopped
    case queued
    case playing(progress: Double)
}

/// The state of the open window: the project, the audio engine, the selection, and undo.
/// Every edit goes through `apply`, which is the same `Command` path the MCP server uses.
@MainActor @Observable
final class AppModel {
    // Project
    private(set) var project: Project
    private(set) var packageURL: URL
    private(set) var waveforms: [AssetID: [Float]] = [:]
    private(set) var simulation = SessionSimulation(events: [], warnings: [])
    private(set) var warnings: [String] = []
    private(set) var dirty = false
    var status = ""

    // UI state
    var viewMode: ViewMode = .session
    var sidebarTab: SidebarTab = .audio
    var detailOpen = true
    var selectedClip: ClipID?
    var selectedTrack: TrackID?
    var pixelsPerBar: Double = 90
    private(set) var transportPlaying = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var previewing: URL?
    var audioFolders: [URL] = []

    // Engine
    @ObservationIgnored let engine: LiveEngine
    @ObservationIgnored private var bank = AudioBank()
    @ObservationIgnored private var plan: RenderPlan?
    @ObservationIgnored private var performance: [Launch] = []
    @ObservationIgnored private var undoStack: [Command] = []
    @ObservationIgnored private var redoStack: [Command] = []
    @ObservationIgnored private var lastKey: (String, Date)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var meterHold: [Int: Float] = [:]

    static let projectsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LoopStudio Projects", isDirectory: true)

    init() {
        let url = Self.projectsFolder.appendingPathComponent("Demo Set.loopstudio")
        let initial = Project(name: "Demo Set")
        project = initial
        packageURL = url
        engine = LiveEngine(sampleRate: initial.sampleRate)
        do { try engine.start() } catch { status = "No audio output: \(error.localizedDescription)" }
        audioFolders = (UserDefaults.standard.stringArray(forKey: "audioFolders") ?? []).map { URL(fileURLWithPath: $0) }

        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else {
            createDemo()
        }
        if ProcessInfo.processInfo.environment["LOOPSTUDIO_SELFTEST"] != nil { runSelfTest() }
    }

    /// Launches scene 1, then prints what the engine plays. Used to check the live path without ears.
    private func runSelfTest() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            launchScene(0)
            var maxPeak: Float = 0
            for second in 1...6 {
                try? await Task.sleep(for: .seconds(1))
                let peak = meterLevel(track: nil)
                maxPeak = max(maxPeak, peak)
                let playing = project.tracks.filter {
                    if case .playing = slotState(track: $0, row: 0, at: currentTick) { true } else { false }
                }.map(\.name)
                FileHandle.standardError.write(Data("selftest t=\(second)s pos=\(positionText()) master peak=\(String(format: "%.3f", peak)) playing=\(playing)\n".utf8))
            }
            FileHandle.standardError.write(Data("selftest max peak \(maxPeak) events=\(simulation.events.count)\n".utf8))
            exit(maxPeak > 0.01 ? 0 : 3)
        }
    }

    // MARK: Time

    var sampleRate: Double { project.sampleRate }
    var bpm: Double { project.tempoMap.bpm(at: 0) }
    var currentFrame: Int64 { engine.positionFrame }
    var currentTick: Tick { project.tempoMap.tick(atFrame: Frame(currentFrame), sampleRate: sampleRate) }
    var ticksPerBar: Int64 { project.timeSignatures.first?.signature.ticksPerBar.rawValue ?? 3840 }
    var barTicks: Int64 { ticksPerBar }

    func frame(_ tick: Tick) -> Int64 { project.tempoMap.frame(at: tick, sampleRate: sampleRate).rawValue }

    /// "bar.beat.sixteenth", counted from 1.
    func positionText() -> String {
        let t = max(0, currentTick.rawValue)
        let bar = t / barTicks + 1
        let inBar = t % barTicks
        let beat = inBar / Tick.perQuarter + 1
        let sixteenth = (inBar % Tick.perQuarter) / (Tick.perQuarter / 4) + 1
        return "\(bar). \(beat). \(sixteenth)"
    }

    func timeText() -> String {
        let s = Double(currentFrame) / sampleRate
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    // MARK: Transport

    func togglePlay() { transportPlaying ? pause() : play() }

    func play() {
        engine.play()
        transportPlaying = true
    }

    func pause() {
        engine.pause()
        transportPlaying = false
    }

    /// First press stops. A second press, with the transport already stopped, goes back to the start.
    func stop() {
        if transportPlaying {
            pause()
        } else {
            engine.seek(to: 0)
        }
        if !performance.isEmpty { performance = []; rebuild() }
    }

    func seek(to tick: Tick) { engine.seek(to: frame(max(0, tick))) }

    var arrangementOverridden: Bool { !performance.isEmpty }

    func backToArrangement() {
        performance = []
        rebuild()
    }

    func toggleLoop() {
        if project.loop?.enabled == true {
            apply(.setLoop(loop: LoopRegion(start: project.loop!.start, end: project.loop!.end, enabled: false)))
        } else {
            let region = project.loop ?? LoopRegion(start: 0, end: Tick(barTicks * 4), enabled: true)
            apply(.setLoop(loop: LoopRegion(start: region.start, end: region.end, enabled: true)))
        }
    }

    func setLoop(start: Tick, end: Tick) {
        guard end > start else { return }
        apply(.setLoop(loop: LoopRegion(start: start, end: end, enabled: project.loop?.enabled ?? true)), key: "loop")
    }

    func setBPM(_ value: Double) {
        let v = min(max(value, 20), 999)
        apply(.setTempoPoints(points: [TempoPoint(tick: 0, bpm: v)]), key: "bpm")
    }

    // MARK: Session launching

    func launch(track: TrackID, row: Int) {
        guard let t = project.track(track), row < t.slots.count, t.slots[row] != nil else { return }
        startIfStopped()
        performance.append(Launch(track: track, slot: row, tick: currentTick))
        rebuild()
    }

    func launchScene(_ row: Int) {
        let ids = project.tracks.filter { row < $0.slots.count && $0.slots[row] != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        startIfStopped()
        let now = currentTick
        for id in ids { performance.append(Launch(track: id, slot: row, tick: now)) }
        rebuild()
    }

    func stopTrack(_ track: TrackID) {
        guard transportPlaying else { return }
        performance.append(Launch(track: track, slot: nil, tick: project.barBoundary(atOrAfter: currentTick)))
        rebuild()
    }

    func stopAllClips() {
        guard transportPlaying else { return }
        let at = project.barBoundary(atOrAfter: currentTick)
        for t in project.tracks where !t.slots.isEmpty { performance.append(Launch(track: t.id, slot: nil, tick: at)) }
        rebuild()
    }

    private func startIfStopped() {
        guard !transportPlaying else { return }
        if performance.isEmpty == false { performance = [] }
        play()
    }

    func slotState(track: Track, row: Int, at tick: Tick) -> SlotState {
        guard row < track.slots.count, let slot = track.slots[row] else { return .empty }
        let events = simulation.events.filter { $0.track == track.id }
        if let e = events.first(where: { $0.startTick <= tick && tick < $0.endTick }), e.slot == row {
            let length = max(1, slot.clip.length.rawValue)
            return .playing(progress: Double((tick - e.startTick).rawValue % length) / Double(length))
        }
        if let next = events.filter({ $0.startTick > tick }).min(by: { $0.startTick < $1.startTick }),
           next.slot == row, next.cause == .launch { return .queued }
        return .stopped
    }

    // MARK: Editing

    func apply(_ command: Command, key: String? = nil) {
        do {
            let inverse = try command.apply(to: &project)
            if let key, let last = lastKey, last.0 == key, Date().timeIntervalSince(last.1) < 0.8, !undoStack.isEmpty {
                lastKey = (key, Date()) // same gesture: keep the first inverse
            } else {
                undoStack.append(inverse)
                lastKey = key.map { ($0, Date()) }
            }
            redoStack.removeAll()
            changed()
        } catch {
            status = "Not possible: \(error)"
        }
    }

    func undo() {
        guard let inverse = undoStack.popLast() else { return }
        if let redo = try? inverse.apply(to: &project) { redoStack.append(redo) }
        lastKey = nil
        changed()
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        if let inverse = try? command.apply(to: &project) { undoStack.append(inverse) }
        lastKey = nil
        changed()
    }

    private func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        dirty = true
        if let c = selectedClip, project.findClip(c) == nil { selectedClip = nil }
        rebuild()
        scheduleSave()
    }

    func addTrack(kind: TrackKind = .audio) {
        let n = project.tracks.count
        let names: [TrackKind: String] = [.audio: "Audio", .midi: "MIDI", .group: "Group", .returnTrack: "Return"]
        let t = Track(name: "\(n + 1) \(names[kind] ?? "Track")", kind: kind, colorIndex: n)
        apply(.insertTrack(track: t, index: n))
    }

    func deleteSelected() {
        guard let id = selectedClip, let (track, clip) = project.findClip(id) else { return }
        if let t = project.track(track), let row = t.slots.firstIndex(where: { $0?.clip.id == id }) {
            apply(.setSlot(track: track, index: row, slot: nil))
        } else {
            apply(.removeClip(clip: clip.id))
        }
    }

    func removeTrack(_ id: TrackID) { apply(.removeTrack(id: id)) }

    func duplicateSlot(track: TrackID, row: Int) {
        guard let t = project.track(track), row < t.slots.count, var slot = t.slots[row] else { return }
        let target = (t.slots.indices.first { $0 > row && t.slots[$0] == nil }) ?? t.slots.count
        switch slot.clip {
        case .audio(var c): c.id = ClipID(); slot.clip = .audio(c)
        case .midi(var c): c.id = ClipID(); slot.clip = .midi(c)
        case .dummy(var c): c.id = ClipID(); slot.clip = .dummy(c)
        }
        apply(.setSlot(track: track, index: target, slot: slot))
    }

    // MARK: Audio import and drop

    @discardableResult
    func importAudio(_ url: URL) -> Asset? {
        do {
            let imported = try AssetStore.importFile(url, into: packageURL)
            if let existing = project.assets.first(where: { $0.sha256 == imported.sha256 }) {
                loadAudio(existing)
                return existing
            }
            var asset = imported
            asset.name = url.deletingPathExtension().lastPathComponent
            try Command.addAsset(asset: asset).apply(to: &project) // not an undo step: the file stays in the project
            loadAudio(asset)
            return asset
        } catch {
            status = "Cannot import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    private func loadAudio(_ asset: Asset) {
        guard bank.buffer(for: asset.id) == nil, let file = AssetStore.fileURL(for: asset, in: packageURL) else { return }
        do {
            let pcm = try AudioBank.decode(file, targetRate: sampleRate)
            bank.insert(pcm, for: asset.id)
            waveforms[asset.id] = Self.peaks(of: pcm, bins: 1_000)
        } catch {
            status = "Cannot read \(asset.name): \(error.localizedDescription)"
        }
    }

    private static func peaks(of pcm: PCMBuffer, bins: Int) -> [Float] {
        let n = max(1, pcm.frames / bins)
        let l = pcm.channel(0), r = pcm.channel(1)
        return (0..<bins).map { b in
            var peak: Float = 0
            let from = b * n, to = min(pcm.frames, from + n)
            if from < to { for i in from..<to { peak = max(peak, abs(l[i]), abs(r[i])) } }
            return peak
        }
    }

    private func lengthTicks(of asset: Asset, from start: Tick) -> Tick {
        let seconds = Double(asset.frames) / max(1, asset.sampleRate)
        let map = project.tempoMap
        let end = map.tick(atSeconds: map.seconds(at: start) + seconds)
        return Tick(max(1, (end - start).rawValue))
    }

    @discardableResult
    func dropOnSlot(_ urls: [URL], track: TrackID, row: Int) -> Bool {
        guard let t = project.track(track), t.kind == .audio else { status = "Audio files go on audio tracks"; return false }
        var at = row
        for url in urls {
            guard let asset = importAudio(url) else { continue }
            var length = lengthTicks(of: asset, from: 0)
            let clip = project.makeAudioClip(asset: asset.id, start: 0, length: length)
            length = clip.length
            apply(.setSlot(track: track, index: at, slot: SessionSlot(clip: .audio(clip))))
            selectedClip = clip.id
            at += 1
        }
        return true
    }

    @discardableResult
    func dropOnTimeline(_ urls: [URL], track: TrackID, at tick: Tick) -> Bool {
        guard let t = project.track(track), t.kind == .audio else { status = "Audio files go on audio tracks"; return false }
        var start = snap(tick)
        for url in urls {
            guard let asset = importAudio(url) else { continue }
            let length = lengthTicks(of: asset, from: start)
            let clip = project.makeAudioClip(asset: asset.id, start: start, length: length)
            apply(.insertClip(track: track, clip: .audio(clip)))
            selectedClip = clip.id
            start = start + length
        }
        return true
    }

    /// Dropping files on empty space makes a new audio track for each file.
    @discardableResult
    func dropOnNewTrack(_ urls: [URL]) -> Bool {
        for url in urls {
            addTrack(kind: .audio)
            guard let t = project.tracks.last else { continue }
            dropOnSlot([url], track: t.id, row: 0)
            apply(.setTrackName(id: t.id, name: url.deletingPathExtension().lastPathComponent))
        }
        return true
    }

    func snap(_ tick: Tick) -> Tick {
        let grid = Tick.perQuarter
        return Tick(max(0, (tick.rawValue + grid / 2) / grid * grid))
    }

    // MARK: Lookup

    func assetName(_ id: AssetID) -> String { project.asset(id)?.name ?? "missing" }

    func clipName(_ clip: Clip) -> String {
        switch clip {
        case .audio(let c): assetName(c.asset)
        case .midi: "MIDI clip"
        case .dummy(let c): c.name.isEmpty ? "Dummy" : c.name
        }
    }

    func assetURL(_ asset: Asset) -> URL? { AssetStore.fileURL(for: asset, in: packageURL) }

    // MARK: Meters

    /// Meter level for a track (or master with `nil`), 0 to about 2, with fast attack and slow release.
    func meterLevel(track: TrackID?) -> Float {
        guard let plan, let index = plan.trackOrder.firstIndex(where: { $0 == track }) else { return 0 }
        let peak = engine.takePeak(node: index)
        let held = max(peak, (meterHold[index] ?? 0) * 0.86)
        meterHold[index] = held
        return held
    }

    // MARK: Engine plan

    private func rebuild() {
        var p = project
        p.launches = performance
        // A track that was launched from the session stops playing its arrangement (like Live).
        let launched = Set(performance.map(\.track))
        for i in p.tracks.indices where launched.contains(p.tracks[i].id) { p.tracks[i].clips = [] }

        let horizon = Tick(barTicks * 300)
        simulation = SessionSimulator.run(p, horizon: horizon)
        let compiled = RenderPlan.compile(p, bank: bank, session: simulation)
        plan = compiled
        warnings = compiled.warnings
        engine.setRenderer(Renderer(plan: compiled))
        if let loop = project.loop, loop.enabled, loop.end > loop.start {
            engine.setLoop(frame(loop.start)..<frame(loop.end))
        } else {
            engine.setLoop(nil)
        }
    }

    // MARK: Files and projects

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try ProjectPackage.write(project, to: packageURL)
            dirty = false
            UserDefaults.standard.set(packageURL.path, forKey: "lastProject")
        } catch {
            status = "Cannot save: \(error.localizedDescription)"
        }
    }

    func projectPackages() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.projectsFolder.path)) ?? []
        return names.filter { $0.hasSuffix(".loopstudio") }.sorted().map { Self.projectsFolder.appendingPathComponent($0) }
    }

    func newProject() {
        save()
        var n = 1
        var url: URL
        repeat {
            url = Self.projectsFolder.appendingPathComponent(n == 1 ? "Untitled.loopstudio" : "Untitled \(n).loopstudio")
            n += 1
        } while FileManager.default.fileExists(atPath: url.path)
        reset(to: Project(name: url.deletingPathExtension().lastPathComponent), at: url)
        for _ in 0..<4 { addTrack() }
        undoStack = []; redoStack = []; canUndo = false; canRedo = false
        save()
    }

    func open(_ url: URL) {
        do {
            let loaded = try ProjectPackage.read(from: url)
            reset(to: loaded.project, at: url)
            for asset in project.assets { loadAudio(asset) }
            rebuild()
            UserDefaults.standard.set(url.path, forKey: "lastProject")
        } catch {
            status = "Cannot open \(url.lastPathComponent): \(error)"
            if project.tracks.isEmpty { createDemo() }
        }
    }

    private func reset(to new: Project, at url: URL) {
        pause()
        engine.seek(to: 0)
        project = new
        packageURL = url
        bank = AudioBank()
        waveforms = [:]
        performance = []
        undoStack = []; redoStack = []
        canUndo = false; canRedo = false
        selectedClip = nil; selectedTrack = nil
        dirty = false
        rebuild()
    }

    // MARK: Preview (browser)

    func togglePreview(_ url: URL) {
        if previewing == url { player?.stop(); previewing = nil; return }
        player?.stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            previewing = url
        } catch {
            previewing = nil
            status = "Cannot play \(url.lastPathComponent)"
        }
    }

    func stopPreviewIfDone() {
        if let player, !player.isPlaying { previewing = nil }
    }

    func addAudioFolder(_ url: URL) {
        guard !audioFolders.contains(url) else { return }
        audioFolders.append(url)
        UserDefaults.standard.set(audioFolders.map(\.path), forKey: "audioFolders")
    }

    func removeAudioFolder(_ url: URL) {
        audioFolders.removeAll { $0 == url }
        UserDefaults.standard.set(audioFolders.map(\.path), forKey: "audioFolders")
    }

    // MARK: Demo

    private func createDemo() {
        DemoSamples.ensure()
        try? FileManager.default.removeItem(at: Self.projectsFolder.appendingPathComponent("Demo Set.loopstudio"))
        reset(to: Project(name: "Demo Set"), at: Self.projectsFolder.appendingPathComponent("Demo Set.loopstudio"))

        let layout: [(String, Int, [String?])] = [
            ("Drums", 0, ["Drums A", "Drums B", "Drums C Fill", nil, "Crash"]),
            ("Bass", 3, ["Bass 1", "Bass 2"]),
            ("Pad", 5, ["Pad Am", "Pad F"]),
            ("Arp", 6, ["Arp"]),
            ("Hits", 1, [nil, nil, nil, nil, "Clap"]),
        ]
        for (index, (name, color, _)) in layout.enumerated() {
            // -4 dB each: four loud loops at once must not clip the master.
            try? Command.insertTrack(track: Track(name: name, kind: .audio, colorIndex: color, volumeDb: -4), index: index).apply(to: &project)
        }
        for (index, (_, _, samples)) in layout.enumerated() {
            let trackID = project.tracks[index].id
            for (row, sample) in samples.enumerated() {
                guard let sample, let asset = importAudio(DemoSamples.url(sample)) else { continue }
                var clip = project.makeAudioClip(asset: asset.id, start: 0, length: lengthTicks(of: asset, from: 0))
                if sample == "Crash" || sample == "Clap" { clip.loop = false }
                var slot = SessionSlot(clip: .audio(clip))
                if index == 0, row < 3 {
                    // Drums: a block of three. Mostly forward, sometimes anywhere in the block.
                    slot.follow = FollowActions(a: FollowAction(.next, weight: 3), b: FollowAction(.any, weight: 1),
                                                time: .loops(2), edge: .wrap)
                }
                try? Command.setSlot(track: trackID, index: row, slot: slot).apply(to: &project)
            }
        }
        // A short arrangement on its own tracks, so the timeline has something in it.
        let bar = barTicks
        if let a = project.assets.first(where: { $0.name == "Drums A" }), let b = project.assets.first(where: { $0.name == "Bass 1" }) {
            var drums = project.makeAudioClip(asset: a.id, start: 0, length: Tick(bar * 4)); drums.loop = true
            var bass = project.makeAudioClip(asset: b.id, start: Tick(bar * 2), length: Tick(bar * 4)); bass.loop = true
            try? Command.insertClip(track: project.tracks[0].id, clip: .audio(drums)).apply(to: &project)
            try? Command.insertClip(track: project.tracks[1].id, clip: .audio(bass)).apply(to: &project)
        }
        undoStack = []; redoStack = []; canUndo = false; canRedo = false
        rebuild()
        save()
    }
}
