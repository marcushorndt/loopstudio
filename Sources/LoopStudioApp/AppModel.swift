import AppKit
import AVFoundation
import Foundation
import LoopStudioCore
import LoopStudioEngine
import LoopStudioProject
import Observation
import UniformTypeIdentifiers
import os

/// A marked time range over one or more tracks in the arrangement.
struct RangeSelection: Equatable {
    var start: Tick
    var end: Tick
    var tracks: Set<TrackID>
}

/// Notes from MIDI devices that sound now, by channel and pitch, with their track. Used on the CoreMIDI thread only.
final class HeldNotes: @unchecked Sendable {
    var tracks: [UInt16: TrackID] = [:]
}

/// The track that live MIDI goes to. Written on the main thread, read on a CoreMIDI thread, always as one value.
final class LiveTarget: Sendable {
    struct State: Sendable {
        var track: TrackID?
        /// The MIDI input of the selected track. `enabled` false means "No Input".
        var enabled = true
        var source: Int32?
        var channel: UInt8?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var current: State { state.withLock { $0 } }
    func set(_ new: State) { state.withLock { $0 = new } }
}

enum ViewMode: String { case session, arrangement }
enum DetailTab { case clip, devices }
/// What the main area of the clip inspector shows.
enum ClipPage { case content, gain, automation }
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
    private(set) var exporting = false
    private(set) var waveforms: [AssetID: [Float]] = [:]
    private(set) var simulation = SessionSimulation(events: [], warnings: [])
    private(set) var warnings: [String] = []
    private(set) var dirty = false
    var status = ""

    // UI state
    var viewMode: ViewMode = .session
    var sidebarTab: SidebarTab = SidebarTab(rawValue: UserDefaults.standard.string(forKey: "sidebarTab") ?? "") ?? .audio {
        didSet { UserDefaults.standard.set(sidebarTab.rawValue, forKey: "sidebarTab") }
    }
    var detailOpen = true
    /// Height of the inspector, kept per Mac.
    var detailHeight: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "detailHeight") as? Double ?? 260) {
        didSet { UserDefaults.standard.set(Double(detailHeight), forKey: "detailHeight") }
    }
    /// The computer keyboard plays the selected MIDI track.
    var keyboardMIDI = false
    /// What the clip inspector shows: the sample or notes, the gain envelope, or the clip automation.
    var clipPage: ClipPage = .content
    /// Automation lanes shown in the clip inspector, per clip. Missing: the lanes that hold points.
    var clipLanesShown: [ClipID: [ParameterAddress]] = [:]
    /// Name of the active colour theme, kept per Mac. Changing it repaints the whole window.
    var themeName: String = UserDefaults.standard.string(forKey: "theme") ?? ThemePalette.zincDark.name {
        didSet {
            UserDefaults.standard.set(themeName, forKey: "theme")
            Theme.palette = ThemePalette.named(UserDefaults.standard.string(forKey: "theme"))
        }
    }
    var isLightTheme: Bool { themeName == ThemePalette.zincLight.name }
    var keyboardOctave = 3
    var keyboardVelocity = 100
    var detailTab: DetailTab = .clip
    var selectedClip: ClipID? {
        // One selection: no clip in focus means no marked clips either, so Delete cannot hit a clip out of view.
        didSet {
            if let c = selectedClip { if !selectedClips.contains(c) { selectedClips = [c] } } else if oldValue != nil { selectedClips = [] }
        }
    }
    /// All marked clips. `selectedClip` is the one the clip panel shows.
    var selectedClips: Set<ClipID> = []
    var rangeSelection: RangeSelection?
    var clipboard: [ClipboardItem] = []
    /// Record is prepared with R. Space then starts it.
    var recordArmed = false
    var recording = false
    var metronomeOn = false
    /// Bars of click before recording starts. 0 means none.
    var countInBars: Int = UserDefaults.standard.object(forKey: "countInBars") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(countInBars, forKey: "countInBars") }
    }
    var recordStartTick: Tick = 0
    /// Audio input for recording. Like the output, it belongs to this Mac.
    var inputUID: String? = UserDefaults.standard.string(forKey: "inputUID") {
        didSet { UserDefaults.standard.set(inputUID, forKey: "inputUID") }
    }
    var inputLeft: Int = UserDefaults.standard.object(forKey: "inputLeft") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(inputLeft, forKey: "inputLeft") }
    }
    var inputStereo: Bool = UserDefaults.standard.object(forKey: "inputStereo") as? Bool ?? false {
        didSet { UserDefaults.standard.set(inputStereo, forKey: "inputStereo") }
    }
    @ObservationIgnored let audioRecorder = AudioInputRecorder()
    /// Records another track's sound (the track's "Audio From"), straight from the renderer.
    @ObservationIgnored var resampleWriter: CaptureWriter?
    /// Plugin latency of the track that a resampling take records, in frames.
    @ObservationIgnored var resampleLatency = 0
    var recordingAudio = false
    var recordTrackID: TrackID?
    /// Timeline frame minus session frame when a MIDI take began. Turns its session-clock stamps into timeline frames.
    @ObservationIgnored var recordFrameOffset: Int64 = 0
    /// Session recording: the empty slot the take goes into. `nil` records into the arrangement.
    @ObservationIgnored var recordSlot: Int?
    /// Sound card choice. It belongs to this Mac, not to a project. `nil` means the system default.
    var outputUID: String? = UserDefaults.standard.string(forKey: "outputUID") {
        didSet { UserDefaults.standard.set(outputUID, forKey: "outputUID") }
    }
    var outputLeft: Int = UserDefaults.standard.object(forKey: "outputLeft") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(outputLeft, forKey: "outputLeft") }
    }
    var bufferFrames: Int = UserDefaults.standard.object(forKey: "bufferFrames") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(bufferFrames, forKey: "bufferFrames") }
    }
    @ObservationIgnored let recorder = MIDIRecorder()
    var shortcutsOpen = false
    /// Set to ask the session view to start renaming this track.
    var renameRequest: TrackID?
    /// Set to rename a clip; takes the place of a track rename while a clip is selected.
    var clipRenameRequest: ClipID?
    var selectedSceneRow: Int?
    /// Tracks whose automation row is open in the arrangement, and the parameter each one shows.
    /// The automation lanes shown under each track in the arrangement, top to bottom.
    var automationShown: [TrackID: [ParameterAddress]] = [:]
    /// While a clip of a marked group is dragged, the others follow by this offset.
    var groupDrag: CGSize = .zero
    var selectedTrack: TrackID? {
        didSet { updateLiveTarget() }
    }
    /// Bumped when a plugin finished loading, so the device cards refresh.
    private(set) var pluginRevision = 0
    private(set) var midiSources = 0
    var pixelsPerBar: Double = 90
    var transportPlaying = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var previewing: URL?
    var audioFolders: [URL] = []

    // Engine
    @ObservationIgnored let engine: LiveEngine
    @ObservationIgnored private var bank = AudioBank.live()
    @ObservationIgnored private var warpTask: Task<Void, Never>?
    /// Every edit since the last save, in the package. After a crash, opening the project replays it.
    /// No fsync per edit, so a fader drag never waits for the disk; an app crash still keeps the file.
    @ObservationIgnored private var journal: Journal?
    @ObservationIgnored private var warpRounds = 0
    @ObservationIgnored private(set) var plan: RenderPlan?
    @ObservationIgnored private var renderer: Renderer?
    @ObservationIgnored private var performance: [Launch] = []
    @ObservationIgnored private var undoStack: [Command] = []
    @ObservationIgnored private var redoStack: [Command] = []
    @ObservationIgnored private var lastKey: (String, Date)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var meterHold: [Int: Float] = [:]
    @ObservationIgnored let host = PluginHost()
    @ObservationIgnored private var midiMonitor: MIDIInputMonitor?
    @ObservationIgnored private let liveTarget = LiveTarget()
    /// Keyboard and piano-roll notes that sound now, with the render node that got them.
    @ObservationIgnored private var heldKeys: [UInt8: TrackID] = [:]

    static let projectsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LoopStudio Projects", isDirectory: true)

    init() {
        Theme.palette = ThemePalette.named(UserDefaults.standard.string(forKey: "theme"))
        let url = Self.projectsFolder.appendingPathComponent("Demo Set.loopstudio")
        let initial = Project(name: "Demo Set")
        project = initial
        packageURL = url
        engine = LiveEngine(sampleRate: initial.sampleRate)
        do { try engine.start() } catch { status = "No audio output: \(error.localizedDescription)" }
        applyAudioSettings()
        startMIDI()
        watchHorizon()
        audioFolders = (UserDefaults.standard.stringArray(forKey: "audioFolders") ?? []).map { URL(fileURLWithPath: $0) }

        // Never overwrite a project at startup: open the last one, else the existing demo, else make a new demo.
        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else if FileManager.default.fileExists(atPath: url.path) {
            open(url)
        } else {
            createDemo()
        }
        if ProcessInfo.processInfo.environment["LOOPSTUDIO_SELFTEST"] != nil { runSelfTest() }
        // Quitting within the autosave delay must not lose the last edit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.dirty == true { self?.save() } }
        }
    }

    /// Launches scene 1, then prints what the engine plays. Used to check the live path without ears.
    private func runSelfTest() {
        Task { @MainActor in
            newDemoProject()
            try? await Task.sleep(for: .seconds(1))
            launchScene(0)
            var maxPeak: Float = 0
            for second in 1...6 {
                try? await Task.sleep(for: .seconds(1))
                let peak = meterLevel(track: nil)
                maxPeak = max(maxPeak, peak)
                let playing = project.tracks.filter {
                    if case .playing = slotState(track: $0, row: 0, at: sessionTick) { true } else { false }
                }.map(\.name)
                let perTrack = project.tracks.map { "\($0.name)=\(String(format: "%.2f", meterLevel(track: $0.id)))" }.joined(separator: " ")
                FileHandle.standardError.write(Data("selftest tracks \(perTrack)\n".utf8))
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
    /// The session clock as a tick. Launches and slot states use it; it does not jump back at the loop end.
    var sessionTick: Tick { project.tempoMap.tick(atFrame: Frame(engine.sessionFrame), sampleRate: sampleRate) }
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

    /// Where Space started playback. Stopping with Space returns here.
    private var playStart: Tick = 0

    /// Space: play from the cursor, or stop and return to where playback began.
    func togglePlay() {
        if transportPlaying {
            pause()
            seek(to: playStart)
        } else {
            playStart = currentTick
            if recordArmed { startRecording() } else { play() }
        }
    }

    // MARK: Recording

    /// R: get ready to record. Space starts it.
    func toggleRecordArm() {
        if recording { finishRecording(); return }
        if !recordArmed {
            guard recordTargetOK() else { return }
            status = countInBars > 0 ? "Record armed. Space starts it after \(countInBars) bar\(countInBars == 1 ? "" : "s") of count-in." : "Record armed. Space starts it."
        } else {
            status = ""
        }
        recordArmed.toggle()
    }

    private func recordTargetOK() -> Bool {
        guard let id = selectedTrack, let t = project.track(id) else { status = "Select an audio or MIDI track to record"; return false }
        guard t.kind == .midi || t.kind == .audio else { status = "Select an audio or MIDI track to record"; return false }
        return true
    }

    private func startRecording() {
        guard recordTargetOK() else { recordArmed = false; play(); return }
        if let id = selectedTrack, project.track(id)?.kind == .audio {
            Task { @MainActor in await startAudioRecording() }
            return
        }
        recordStartTick = currentTick
        // The take belongs to this track, even if the selection changes while it records.
        recordTrackID = selectedTrack
        recordSlot = selectedTrack.flatMap(sessionRecordSlot)
        // Notes are stamped on the session clock, which does not jump back at the loop end.
        recordFrameOffset = engine.positionFrame - engine.sessionFrame
        recorder.begin()
        recording = true
        updateMetronome()
        engine.playAfterCountIn(beats: countInBars * meter.beats)
        transportPlaying = true
        status = recordSlot.map { "Recording into slot \($0 + 1)" } ?? "Recording"
    }

    /// Turns what was played into a MIDI clip on the selected track.
    func finishRecording() {
        guard recording else { return }
        recording = false
        recordArmed = false
        if recordingAudio { finishAudioRecording(); return }
        let events = recorder.end()
        guard let id = recordTrackID, project.track(id)?.kind == .midi else { recordTrackID = nil; status = "Nothing recorded"; return }
        recordTrackID = nil
        let offset = recordFrameOffset
        let endFrame = engine.sessionFrame
        let sr = sampleRate, map = project.tempoMap, start = recordStartTick.rawValue
        let notes = MIDIRecorder.notes(from: events, endFrame: endFrame) { frame in
            max(0, map.tick(atFrame: Frame(frame + offset), sampleRate: sr).rawValue - start)
        }
        guard !notes.isEmpty else { status = "Nothing recorded"; return }
        let elapsed = max(1, project.tempoMap.tick(atFrame: Frame(endFrame + offset), sampleRate: sr).rawValue - start)
        let bars = max(1, (elapsed + barTicks - 1) / barTicks)
        let clip = MIDIClip(start: recordStartTick, length: Tick(bars * barTicks), loop: false, notes: notes)
        placeTake(.midi(clip), on: id)
        status = "Recorded \(notes.count) note\(notes.count == 1 ? "" : "s")"
    }

    func toggleMetronome() { metronomeOn.toggle(); updateMetronome() }

    /// The meter where playback stands: beats per bar, and how long one beat is (6/8 counts eighths).
    var meter: (beats: Int, beatTicks: Int64) {
        let here = currentTick
        let sig = project.timeSignatures.sorted { $0.tick < $1.tick }.last { $0.tick <= here }?.signature
            ?? project.timeSignatures.first?.signature ?? TimeSignature(4, 4)
        return (sig.numerator, sig.ticksPerBar.rawValue / Int64(max(1, sig.numerator)))
    }

    /// The count-in uses the tempo and meter where playback starts; the song click follows both maps.
    func updateMetronome() {
        let here = currentTick
        let quarter = (60.0 / max(20, project.tempoMap.bpm(at: here))) * sampleRate
        let beat = Int64(quarter * Double(meter.beatTicks) / Double(Tick.perQuarter))
        engine.setMetronome(enabled: metronomeOn, beatFrames: beat, beatsPerBar: meter.beats)
        guard metronomeOn else { engine.setClickGrid(frames: [], accents: []); return }
        let beats = project.clickBeats(upTo: max(planHorizon, here + Tick(barTicks * 300)))
        let map = project.tempoMap, sr = sampleRate
        engine.setClickGrid(frames: beats.map { map.frame(at: $0.tick, sampleRate: sr).rawValue }, accents: beats.map(\.accent))
    }

    /// Shift+Space: pause in place, or continue from there.
    func togglePause() { transportPlaying ? pause() : play() }

    func play() {
        engine.play()
        transportPlaying = true
    }

    func pause() {
        if recording { finishRecording() }
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

    func seek(to tick: Tick) {
        engine.seek(to: frame(max(0, tick)))
        if !transportPlaying { playStart = max(0, tick) }
    }

    var arrangementOverridden: Bool { !performance.isEmpty }

    func backToArrangement() {
        performance = []
        rebuild()
    }

    // MARK: Arrangement rows

    static let clipRow: CGFloat = 74
    static let automationRow: CGFloat = 76

    func rowHeight(_ track: Track) -> CGFloat { Self.clipRow + CGFloat(shownLanes(track).count) * Self.automationRow }
    /// Tracks in the order the views show them: normal and group tracks, then the busses (returns).
    /// The session keeps busses at the right edge, the arrangement keeps them at the bottom.
    var orderedTracks: [Track] {
        project.tracks.filter { $0.kind != .returnTrack } + project.tracks.filter { $0.kind == .returnTrack }
    }

    func rowTop(_ index: Int) -> CGFloat { orderedTracks.prefix(index).reduce(0) { $0 + rowHeight($1) } }
    var rowsHeight: CGFloat { max(Self.clipRow, orderedTracks.reduce(0) { $0 + rowHeight($1) }) + rowHeight(project.master) }

    /// The track row at a height measured from the top of the first row.
    func rowIndex(atY y: CGFloat) -> Int {
        var top: CGFloat = 0
        let tracks = orderedTracks
        for (i, t) in tracks.enumerated() {
            top += rowHeight(t)
            if y < top { return i }
        }
        return max(0, tracks.count - 1)
    }

    /// Double-click on a track: select it and show it in the inspector.
    func openTrackInspector(_ id: TrackID) {
        selectedTrack = id
        detailTab = .devices
        detailOpen = true
    }

    /// Lanes shown for a track, without parameters that no longer exist.
    func shownLanes(_ track: Track) -> [ParameterAddress] {
        guard let shown = automationShown[track.id], !shown.isEmpty else { return [] }
        let valid = Set(project.automationTargets(of: track).map(\.address))
        return shown.filter { valid.contains($0) }
    }

    func isLaneShown(_ track: Track, _ address: ParameterAddress) -> Bool { shownLanes(track).contains(address) }

    func setLane(_ track: Track, _ address: ParameterAddress, shown: Bool) {
        var list = automationShown[track.id] ?? []
        list.removeAll { $0 == address }
        if shown { list.append(address) }
        automationShown[track.id] = list.isEmpty ? nil : list
    }

    /// Shows the lanes that already hold points; with none, shows volume. A second call hides all lanes.
    func toggleAutomation(_ track: Track) {
        if !shownLanes(track).isEmpty { automationShown[track.id] = nil; return }
        let used = track.automation.filter { !$0.points.isEmpty }.map(\.target)
        let first = project.automationTargets(of: track).first?.address
        automationShown[track.id] = used.isEmpty ? first.map { [$0] } : used
    }

    /// From a knob: shows or hides its curve, and switches to the arrangement so the curve is in view.
    func toggleLaneAndReveal(_ track: Track, _ address: ParameterAddress) {
        let show = !isLaneShown(track, address)
        setLane(track, address, shown: show)
        if show { viewMode = .arrangement; selectedTrack = track.id }
    }

    // MARK: Clip automation

    /// The page of the clip inspector for a clip. A dummy clip has only automation; a MIDI clip has no gain page.
    func page(for clip: Clip) -> ClipPage {
        switch clip {
        case .dummy: return .automation
        case .midi: return clipPage == .gain ? .content : clipPage
        case .audio: return clipPage
        }
    }

    /// The clip lanes the inspector shows: the user's choice, else the lanes with points.
    func shownClipLanes(_ clip: Clip, owner: Track) -> [ParameterAddress] {
        let valid = Set(project.clipAutomationTargets(clip, owner: owner).map(\.address))
        let list = clipLanesShown[clip.id] ?? clip.lanes.filter { !$0.points.isEmpty }.map(\.target)
        return list.filter { valid.contains($0) }
    }

    func setClipLane(_ clip: Clip, owner: Track, _ address: ParameterAddress, shown: Bool) {
        var list = shownClipLanes(clip, owner: owner)
        list.removeAll { $0 == address }
        if shown { list.append(address) }
        clipLanesShown[clip.id] = list
        if shown { clipPage = .automation }
    }

    /// Selects a clip and opens its automation in the inspector, with `address` (a clip lane address) in view.
    func openClipAutomation(_ id: ClipID, address: ParameterAddress? = nil) {
        guard let (trackID, clip) = project.findClip(id), let owner = project.track(trackID) else { return }
        selectedClip = id
        selectedTrack = trackID
        detailTab = .clip
        detailOpen = true
        clipPage = .automation
        if let address { setClipLane(clip, owner: owner, address, shown: true) }
    }

    /// The clip lane address for a track parameter: mixer parameters of the clip's own track use `ownTrack`.
    func clipAddress(_ address: ParameterAddress, in clip: Clip, owner: Track) -> ParameterAddress {
        if case .dummy = clip { return address }
        return address.node == owner.id.rawValue ? ParameterAddress(node: ParameterAddress.ownTrack, parameter: address.parameter) : address
    }

    /// Writes an arrangement clip's automation into the track lanes and shows those lanes.
    func moveClipAutomationToTrack(_ id: ClipID) {
        guard let command = project.clipAutomationToTrack(id), let (trackID, clip) = project.findClip(id),
              let owner = project.track(trackID) else { return }
        let targets = project.effectiveLanes(of: clip, owner: owner).map(\.target)
        apply(command)
        for address in targets {
            if let host = project.trackOwning(address) { setLane(host, address, shown: true) }
        }
        clipLanesShown[id] = nil
        status = "Clip automation moved to the track lanes"
    }

    /// Arrangement clips whose automation overrides a track lane, for drawing over that lane.
    func clipOverrides(_ address: ParameterAddress) -> [(clip: Clip, lane: [AutomationPoint], tint: Int)] {
        var result: [(clip: Clip, lane: [AutomationPoint], tint: Int)] = []
        for t in project.allTracks {
            for clip in t.clips {
                if case .audio(let a) = clip, a.muted { continue }
                if let lane = project.effectiveLanes(of: clip, owner: t).first(where: { $0.target == address }) {
                    result.append((clip, lane.points, clip.colorIndex ?? t.colorIndex))
                }
            }
        }
        return result
    }

    /// True when any track shows an automation lane in the arrangement.
    var anyLanesShown: Bool { project.allTracks.contains { !shownLanes($0).isEmpty } }

    /// The A key. Arrangement: shows or hides the lanes of every track (the used ones, else volume).
    /// Session: switches the clip inspector between the clip automation and the clip content.
    func toggleAutomationView() {
        if viewMode == .session, let id = selectedClip, let clip = project.findClip(id)?.clip {
            detailTab = .clip
            detailOpen = true
            clipPage = page(for: clip) == .automation ? .content : .automation
            return
        }
        if anyLanesShown { automationShown = [:]; return }
        for t in orderedTracks where t.kind != .master { toggleAutomation(t) }
    }

    func showAllUsedLanes(_ track: Track) {
        automationShown[track.id] = track.automation.filter { !$0.points.isEmpty }.map(\.target)
    }

    func automationPoints(_ track: Track, _ address: ParameterAddress) -> [AutomationPoint] {
        track.automation.first { $0.target == address }?.points ?? []
    }

    // MARK: Selection

    func select(clip id: ClipID, extend: Bool) {
        rangeSelection = nil
        if extend {
            if selectedClips.contains(id) {
                selectedClips.remove(id)
                if selectedClip == id { selectedClip = selectedClips.first }
            } else {
                selectedClips.insert(id)
                selectedClip = id
            }
        } else {
            selectedClips = [id]
            selectedClip = id
        }
    }

    func clearSelection() {
        selectedClips = []
        selectedClip = nil
        rangeSelection = nil
    }

    /// Marks a time range on some tracks. Every arrangement clip that touches it is marked too.
    func selectRange(from a: Tick, to b: Tick, tracks: Set<TrackID>) {
        let start = min(a, b), end = max(a, b)
        guard end > start, !tracks.isEmpty else { return }
        rangeSelection = RangeSelection(start: start, end: end, tracks: tracks)
        var ids = Set<ClipID>()
        for t in project.tracks where tracks.contains(t.id) {
            for c in t.clips where c.start < end && c.start + c.length > start { ids.insert(c.id) }
        }
        selectedClips = ids
        selectedClip = ids.first
    }

    /// Loops the marked range (or the extent of the marked clips) and turns the loop on.
    /// With nothing marked it only switches the loop on or off.
    func loopSelection() {
        var range: (Tick, Tick)?
        if let r = rangeSelection { range = (r.start, r.end) }
        else if !selectedClips.isEmpty {
            let found = selectedClips.compactMap { project.findClip($0)?.clip }
            if let lo = found.map(\.start).min(), let hi = found.map({ $0.start + $0.length }).max() { range = (lo, hi) }
        }
        guard let (start, end) = range, end > start else { toggleLoop(); return }
        apply(.setLoop(loop: LoopRegion(start: start, end: end, enabled: true)))
        if !transportPlaying || currentTick < start || currentTick >= end { seek(to: start) }
    }

    /// Moves every clip in `ids` by the same time and track offset, as one undo step.
    func moveClips(_ ids: [ClipID], deltaTicks: Int64, trackShift: Int) {
        var commands: [Command] = []
        let tracks = orderedTracks
        for id in ids {
            guard let (trackID, clip) = project.findClip(id), let from = tracks.firstIndex(where: { $0.id == trackID }),
                  tracks[from].clips.contains(where: { $0.id == id }) else { continue }
            let to = min(max(0, from + trackShift), tracks.count - 1)
            commands.append(.moveClip(clip: id, toTrack: tracks[to].id, start: Tick(max(0, clip.start.rawValue + deltaTicks))))
        }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
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
        performance.append(Launch(track: track, slot: row, tick: sessionTick))
        rebuild()
    }

    func launchScene(_ row: Int) {
        let ids = project.tracks.filter { row < $0.slots.count && $0.slots[row] != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        startIfStopped()
        let now = sessionTick
        for id in ids { performance.append(Launch(track: id, slot: row, tick: now)) }
        // As in Live, an empty slot in the scene stops its track, on the next bar.
        let stopAt = project.barBoundary(atOrAfter: now)
        for t in project.tracks where !ids.contains(t.id) && !t.slots.isEmpty {
            performance.append(Launch(track: t.id, slot: nil, tick: stopAt))
        }
        rebuild()
    }

    func stopTrack(_ track: TrackID) {
        guard transportPlaying else { return }
        performance.append(Launch(track: track, slot: nil, tick: project.barBoundary(atOrAfter: sessionTick)))
        rebuild()
    }

    /// Stop button of a track, a bus or the master.
    func stopClips(of track: Track) {
        switch track.kind {
        case .master: stopAllClips()
        case .returnTrack, .group:
            guard transportPlaying else { return }
            let at = project.barBoundary(atOrAfter: sessionTick)
            // Every track that reaches this bus: by output, send or input, also through nested groups.
            var reach: Set<TrackID> = [track.id]
            var grew = true
            while grew {
                grew = false
                for t in project.tracks where !reach.contains(t.id) && Routing.feeds(of: t, in: project).contains(where: reach.contains) {
                    reach.insert(t.id); grew = true
                }
            }
            for t in project.tracks where reach.contains(t.id) && !t.slots.isEmpty { performance.append(Launch(track: t.id, slot: nil, tick: at)) }
            rebuild()
        default: stopTrack(track.id)
        }
    }

    func stopAllClips() {
        guard transportPlaying else { return }
        let at = project.barBoundary(atOrAfter: sessionTick)
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

    /// Ticks since the clip began its current play, or `nil` when it does not play now.
    /// Arrangement clips follow the timeline; session clips follow the session clock.
    func clipPlayOffset(_ id: ClipID) -> Tick? {
        guard transportPlaying, let (trackID, clip) = project.findClip(id), let track = project.track(trackID) else { return nil }
        if track.clips.contains(where: { $0.id == id }) {
            let t = currentTick
            return t >= clip.start && t < clip.start + clip.length ? t - clip.start : nil
        }
        guard let row = track.slots.firstIndex(where: { $0?.clip.id == id }) else { return nil }
        let tick = sessionTick
        guard let e = simulation.events.first(where: { $0.track == trackID && $0.startTick <= tick && tick < $0.endTick }),
              e.slot == row else { return nil }
        return tick - e.startTick
    }

    // MARK: Editing

    func apply(_ command: Command, key: String? = nil) {
        do {
            let inverse = try command.apply(to: &project)
            try? journal?.append(command)
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
        if let redo = try? inverse.apply(to: &project) { redoStack.append(redo); try? journal?.append(inverse) }
        lastKey = nil
        changed()
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        if let inverse = try? command.apply(to: &project) { undoStack.append(inverse); try? journal?.append(command) }
        lastKey = nil
        changed()
    }

    private func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        dirty = true
        if let c = selectedClip, project.findClip(c) == nil { selectedClip = nil }
        selectedClips = selectedClips.filter { project.findClip($0) != nil }
        rebuild()
        syncPlugins()
        scheduleSave()
    }

    func addTrack(kind: TrackKind = .audio) {
        let n = project.tracks.count
        let names: [TrackKind: String] = [.audio: "Audio", .midi: "MIDI", .group: "Group", .returnTrack: "Return"]
        let t = Track(name: "\(n + 1) \(names[kind] ?? "Track")", kind: kind, colorIndex: n, midiInput: kind == .midi ? MIDIInputSelection() : nil)
        if kind == .midi {
            // A new MIDI track starts with Apple's built-in synth, so it makes sound at once.
            let synth = DeviceSlot(format: "audiounit", identifier: "aumu/dls /appl", name: "Apple DLS Synth")
            apply(.batch(commands: [.insertTrack(track: t, index: n), .insertDevice(track: t.id, device: synth, index: 0)]))
        } else {
            apply(.insertTrack(track: t, index: n))
        }
        selectedTrack = t.id
    }

    /// Puts the marked tracks (or the selected one) into a new group track. The group sits after the last of them.
    func groupSelectedTracks() {
        let marked = rangeSelection?.tracks ?? Set(selectedTrack.map { [$0] } ?? [])
        let members = project.tracks.filter { marked.contains($0.id) && $0.kind != .returnTrack && $0.kind != .group }
        guard !members.isEmpty else { return }
        let index = (project.tracks.lastIndex { marked.contains($0.id) } ?? project.tracks.count - 1) + 1
        let group = Track(name: "Group \(project.tracks.filter { $0.kind == .group }.count + 1)", kind: .group, colorIndex: project.tracks.count)
        apply(.batch(commands: [.insertTrack(track: group, index: index)] + members.map { .setOutput(id: $0.id, target: group.id) }))
        selectedTrack = group.id
    }

    func deleteSelected() {
        var commands: [Command] = []
        for id in selectedClips.isEmpty ? Set(selectedClip.map { [$0] } ?? []) : selectedClips {
            guard let (track, clip) = project.findClip(id) else { continue }
            if let t = project.track(track), let row = t.slots.firstIndex(where: { $0?.clip.id == id }) {
                commands.append(.setSlot(track: track, index: row, slot: nil))
            } else {
                commands.append(.removeClip(clip: clip.id))
            }
        }
        if !commands.isEmpty { apply(.batch(commands: commands)) }
    }

    func removeTrack(_ id: TrackID) { apply(.removeTrack(id: id)) }

    // MARK: Plugins

    func syncPlugins() {
        Task { @MainActor in
            if await host.sync(project: project) {
                recordPluginParams()
                pluginRevision += 1
                rebuild()
            }
        }
    }

    /// Stores the automatable parameters of each loaded plugin in the project. Not an edit: no undo step.
    private func recordPluginParams() {
        for track in project.allTracks {
            for device in track.devices where device.format == "audiounit" {
                guard let unit = host.units[device.id] else { continue }
                let params = unit.automatableParameters()
                guard params != (device.pluginParams ?? []) else { continue }
                _ = try? Command.setPluginParams(track: track.id, device: device.id, params: params).apply(to: &project)
            }
        }
    }

    /// Writes each plugin's current state into the project, so a save keeps knob positions and presets.
    private func captureStates() {
        let states = host.states()
        guard !states.isEmpty else { return }
        for i in project.tracks.indices {
            for j in project.tracks[i].devices.indices {
                if let data = states[project.tracks[i].devices[j].id] { project.tracks[i].devices[j].state = data }
            }
        }
        for j in project.master.devices.indices {
            if let data = states[project.master.devices[j].id] { project.master.devices[j].state = data }
        }
    }

    func addAudioUnit(identifier: String, name: String, to track: TrackID? = nil) {
        let slot = DeviceSlot(format: "audiounit", identifier: identifier, name: name)
        let target = (track ?? selectedTrack).flatMap { project.track($0) }
        if identifier.hasPrefix("aumu") {
            if let target, target.kind == .midi {
                apply(.insertDevice(track: target.id, device: slot, index: 0))
                selectedTrack = target.id
            } else {
                // An instrument needs a MIDI track. Make one.
                let t = Track(name: name, kind: .midi, colorIndex: project.tracks.count, midiInput: MIDIInputSelection())
                apply(.batch(commands: [.insertTrack(track: t, index: project.tracks.count),
                                        .insertDevice(track: t.id, device: slot, index: 0)]))
                selectedTrack = t.id
            }
        } else {
            guard let target = target ?? project.tracks.first else { status = "Add a track first"; return }
            apply(.insertDevice(track: target.id, device: slot, index: nil))
            selectedTrack = target.id
        }
        detailTab = .devices
        detailOpen = true
    }

    /// Handles items dragged from the sidebar: "fx:<id>" for a built-in effect, "au:<identifier>|<name>" for a plugin.
    @discardableResult
    func dropDevices(_ items: [String], on track: TrackID?) -> Bool {
        var used = false
        for item in items {
            if item.hasPrefix("fx:") { addEffect(String(item.dropFirst(3)), to: track); used = true }
            else if item.hasPrefix("au:") {
                let parts = item.dropFirst(3).split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { addAudioUnit(identifier: parts[0], name: parts[1], to: track); used = true }
            }
        }
        return used
    }

    // MARK: MIDI

    private func startMIDI() {
        let monitor = MIDIInputMonitor()
        let target = liveTarget, engine = engine, recorder = recorder
        let held = HeldNotes()
        monitor.handler = { status, a, b, src, time in
            let t = target.current
            // A release goes where its note went, even after the selection changed.
            let kind = status & 0xF0, key = UInt16(status & 0x0F) << 8 | UInt16(a)
            if kind == 0x80 || (kind == 0x90 && b == 0), let noted = held.tracks.removeValue(forKey: key) {
                engine.sendLiveMIDI(track: noted, status, a, b)
                if engine.isPlaying { recorder.capture(frame: engine.sessionFrame(atHost: time), status, a, b) }
                return
            }
            guard t.enabled, t.source == nil || t.source == src,
                  t.channel == nil || t.channel == status & 0x0F else { return }
            if let track = t.track {
                if kind == 0x90 && b > 0 { held.tracks[key] = track }
                engine.sendLiveMIDI(track: track, status, a, b)
                if engine.isPlaying { recorder.capture(frame: engine.sessionFrame(atHost: time), status, a, b) }
            }
        }
        midiMonitor = monitor
        midiSources = monitor.sourceCount
    }

    /// Points live notes (keyboard, MIDI devices, piano roll clicks) at the selected MIDI track.
    private func updateLiveTarget() {
        guard let id = selectedTrack, let track = project.track(id), track.kind == .midi else { liveTarget.set(.init(track: nil)); return }
        liveTarget.set(.init(track: id, enabled: track.midiInput != nil,
                             source: track.midiInput?.sourceUID, channel: track.midiInput?.channel))
    }

    func noteOn(_ pitch: UInt8, velocity: UInt8 = 100) {
        if let track = liveTarget.current.track {
            heldKeys[pitch] = track
            engine.sendLiveMIDI(track: track, 0x90, pitch, velocity)
            if engine.isPlaying { recorder.capture(frame: engine.sessionFrame, 0x90, pitch, velocity) }
        }
    }

    /// The release goes to the instrument that got the note, even if another track is selected now.
    func noteOff(_ pitch: UInt8) {
        if let track = heldKeys.removeValue(forKey: pitch) ?? liveTarget.current.track {
            engine.sendLiveMIDI(track: track, 0x80, pitch, 0)
            if engine.isPlaying { recorder.capture(frame: engine.sessionFrame, 0x80, pitch, 0) }
        }
    }

    /// A short note, for clicking in the piano roll.
    func auditionNote(_ pitch: UInt8) {
        noteOn(pitch)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            noteOff(pitch)
        }
    }

    func createMIDIClip(track: TrackID, row: Int) {
        let clip = MIDIClip(start: 0, length: Tick(barTicks), loop: true)
        apply(.setSlot(track: track, index: row, slot: SessionSlot(clip: .midi(clip))))
        selectedClip = clip.id
        selectedTrack = track
        detailOpen = true
        detailTab = .clip
    }

    func createMIDIClip(track: TrackID, at tick: Tick) {
        let clip = MIDIClip(start: snap(tick), length: Tick(barTicks * 2))
        apply(.insertClip(track: track, clip: .midi(clip)))
        selectedClip = clip.id
        selectedTrack = track
        detailOpen = true
        detailTab = .clip
    }

    func createDummyClip(track: TrackID, row: Int) {
        let n = project.tracks.flatMap { $0.slots.compactMap { $0?.clip } }.filter { if case .dummy = $0 { true } else { false } }.count + 1
        let clip = DummyClip(name: "Auto \(n)", length: Tick(barTicks * 2))
        apply(.setSlot(track: track, index: row, slot: SessionSlot(clip: .dummy(clip))))
        selectedClip = clip.id
        selectedTrack = track
        detailOpen = true
        detailTab = .clip
    }

    func setNotes(_ clip: ClipID, _ notes: [MIDINote]) {
        apply(.setMIDINotes(clip: clip, notes: notes), key: "notes\(clip)")
    }

    // MARK: Devices

    /// Adds a built-in effect at the end of a track's chain. Without a track it uses the selected one,
    /// then the first audio track.
    func addEffect(_ id: String, to track: TrackID? = nil) {
        guard let slot = BuiltInEffects.makeSlot(id) else { return }
        guard let target = track ?? selectedTrack ?? project.tracks.first?.id else { status = "Add a track first"; return }
        apply(.insertDevice(track: target, device: slot, index: nil))
        selectedTrack = target
        detailTab = .devices
        detailOpen = true
    }

    func setDeviceParam(_ track: TrackID, _ device: DeviceID, _ key: String, _ value: Double?) {
        apply(.setDeviceParam(track: track, device: device, key: key, value: value), key: "dev\(device)\(key)")
    }

    func setSend(from track: Track, to target: TrackID, db: Double) {
        var sends = track.sends
        if let i = sends.firstIndex(where: { $0.target == target }) { sends[i].levelDb = db }
        else { sends.append(Send(target: target, levelDb: db)) }
        apply(.setSends(id: track.id, sends: sends), key: "send\(track.id)\(target)")
    }

    func sendLevel(_ track: Track, to target: TrackID) -> Double {
        track.sends.first { $0.target == target }?.levelDb ?? -96
    }

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
            // The demo loops are made at 120 BPM.
            if url.path.contains("/LoopStudio/Demo Samples/") { asset.sourceTempo = 120 }
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

    /// Decodes every sample of the project on workers, in parallel, so a big project opens at once.
    /// Clips play silence until their audio is in; then one rebuild puts it all in.
    private func loadAllAudio() {
        let assets = project.assets.filter { bank.buffer(for: $0.id) == nil }
        guard !assets.isEmpty else { rebuild(); return }
        let jobs = assets.compactMap { a in AssetStore.fileURL(for: a, in: packageURL).map { (a.id, a.name, $0) } }
        let rate = sampleRate, bank = bank
        status = "Loading \(jobs.count) sample\(jobs.count == 1 ? "" : "s")…"
        rebuild()
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: (AssetID, String, PCMBuffer?, [Float], String?).self) { group in
                    for (id, name, url) in jobs {
                        group.addTask {
                            do {
                                let pcm = try AudioBank.decode(url, targetRate: rate)
                                return (id, name, pcm, AppModel.peaks(of: pcm, bins: 1_000), nil)
                            } catch { return (id, name, nil, [], error.localizedDescription) }
                        }
                    }
                    var all: [(AssetID, String, PCMBuffer?, [Float], String?)] = []
                    for await r in group { all.append(r) }
                    return all
                }
            }.value
            guard let self, self.bank === bank else { return } // another project opened meanwhile
            var failed: [String] = []
            for (id, name, pcm, peaks, error) in results {
                if let pcm { bank.insert(pcm, for: id); self.waveforms[id] = peaks }
                if let error { failed.append("\(name): \(error)") }
            }
            if self.status.hasPrefix("Loading ") { self.status = "" }
            if !failed.isEmpty { self.status = "Cannot read \(failed.prefix(3).joined(separator: "; "))" }
            self.rebuild()
        }
    }

    nonisolated private static func peaks(of pcm: PCMBuffer, bins: Int) -> [Float] {
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
        project.naturalLength(of: asset, from: start)
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
        case .audio(let c): c.name ?? assetName(c.asset)
        case .midi(let c): c.name ?? "MIDI clip"
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

    /// How far the current session plan reaches.
    @ObservationIgnored private var planHorizon = Tick(0)

    /// Rebuilds the plan before the session clock reaches its end. Checked every few seconds.
    private func watchHorizon() {
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(3))
                if transportPlaying, !performance.isEmpty, sessionTick.rawValue > planHorizon.rawValue - barTicks * 100 { rebuild() }
            }
        }
    }

    private func rebuild(afterWarps: Bool = false) {
        var p = project
        p.launches = performance

        // The session clock runs on past the loop end, so the plan reaches 300 bars past it, and is extended in time.
        let horizon = Tick(max(0, sessionTick.rawValue) + barTicks * 300)
        planHorizon = horizon
        simulation = SessionSimulator.run(p, horizon: horizon)
        // A track launched from the session stops its arrangement (like Live), but only when the session
        // really takes over: at the quantized clip start, or at a session stop.
        var ends: [TrackID: Int64] = [:]
        for track in Set(performance.map(\.track)) {
            let starts = simulation.events.filter { $0.track == track }.map(\.startTick)
            let stops = performance.filter { $0.track == track && $0.slot == nil }.map(\.tick)
            if let first = (starts + stops).min() { ends[track] = frame(first) }
        }
        let compiled = RenderPlan.compile(p, bank: bank, session: simulation, units: host.units, arrangementEnds: ends)
        plan = compiled
        warnings = simulation.warnings + compiled.warnings
        updateLiveTarget()
        updateMetronome()
        let next = Renderer(plan: compiled, reusing: renderer)
        renderer = next
        engine.setRenderer(next)
        if let loop = project.loop, loop.enabled, loop.end > loop.start {
            engine.setLoop(frame(loop.start)..<frame(loop.end))
        } else {
            engine.setLoop(nil)
        }
        startWarps(afterWarps: afterWarps)
    }

    /// Time stretching is slow, so the plan does not wait for it: a clip keeps its last warped audio,
    /// a worker makes the new warps, and one more rebuild puts them in. A newer edit cancels the older work.
    private func startWarps(afterWarps: Bool = false) {
        let jobs = bank.takePendingWarps()
        guard !jobs.isEmpty else { warpRounds = 0; return }
        // The cache can hold every warp of a plan, so a second round after the worker is rare and a third means a problem.
        // An edit starts the count again.
        warpRounds = afterWarps ? warpRounds + 1 : 0
        guard warpRounds < 3 else { warpRounds = 0; status = "Some warped clips could not be prepared"; return }
        warpTask?.cancel()
        let bank = bank
        warpTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> Bool in
                for job in jobs {
                    if Task.isCancelled { return false }
                    bank.run(job)
                }
                return true
            }
            let done = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard done, !Task.isCancelled, let self, self.bank === bank else { return }
            self.rebuild(afterWarps: true)
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
        captureStates()
        do {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try ProjectPackage.write(project, to: packageURL)
            dirty = false
            UserDefaults.standard.set(packageURL.path, forKey: "lastProject")
            // The edits are in the package now. A journal that keeps them would apply them twice after a crash.
            do { try journal?.reset() } catch {
                journal = nil
                status = "Saved, but the edit journal is off: \(error.localizedDescription)"
            }
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
        // Unsaved edits of the current project go to disk first; the pending autosave belongs to it.
        if dirty && url != packageURL { save() }
        saveTask?.cancel()
        do {
            let loaded = try ProjectPackage.read(from: url)
            // Edits after the last save, from a session that did not end cleanly.
            let journalURL = url.appendingPathComponent("journal.jsonl")
            let pending = (try? Journal.read(url: journalURL))?.commands ?? []
            let replay = pending.isEmpty ? nil : Journal.replay(pending, onto: loaded.project)
            reset(to: replay?.project ?? loaded.project, at: url)
            loadAllAudio()
            if let replay {
                dirty = true
                scheduleSave()
                status = "Recovered \(replay.applied) unsaved edit\(replay.applied == 1 ? "" : "s")"
                    + (replay.failure == nil ? "" : "; the rest could not be applied")
            }
            syncPlugins()
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            if !loaded.issues.isEmpty {
                status = "Opened with \(loaded.issues.count) problem\(loaded.issues.count == 1 ? "" : "s"): \(loaded.issues.prefix(3).map { "\($0)" }.joined(separator: "; "))"
            }
        } catch {
            status = "Cannot open \(url.lastPathComponent): \(error)"
            if project.tracks.isEmpty { createDemo() }
        }
    }

    /// Saves a copy of the project, with its samples, under a new name, and goes on in the copy.
    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Project As"
        panel.nameFieldStringValue = project.name
        panel.directoryURL = Self.projectsFolder
        panel.allowedContentTypes = [UTType(filenameExtension: "loopstudio") ?? .package]
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "loopstudio" { url.appendPathExtension("loopstudio") }
        guard url.standardizedFileURL != packageURL.standardizedFileURL else { save(); return }
        captureStates()
        let fm = FileManager.default
        do {
            // The panel asked before it allowed a replace; the old package goes to the Trash, not away.
            if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let audio = packageURL.appendingPathComponent("audio", isDirectory: true)
            if fm.fileExists(atPath: audio.path) { try fm.copyItem(at: audio, to: url.appendingPathComponent("audio", isDirectory: true)) }
            var copy = project
            copy.name = url.deletingPathExtension().lastPathComponent
            try ProjectPackage.write(copy, to: url)
            saveTask?.cancel()
            // The old package stays at its last save, as Save As promises. Its journal must not bring the edits back.
            try? journal?.reset()
            project = copy
            packageURL = url
            journal = try? Journal(url: url.appendingPathComponent("journal.jsonl"), durable: false)
            dirty = false
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            status = "Saved as \(url.lastPathComponent)"
        } catch {
            status = "Cannot save as \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Renders the arrangement and the saved Session launches, with hosted plugins, to a 24-bit WAV file.
    /// The render runs off the main thread.
    func exportAudio() {
        guard !exporting else { status = "An export is running"; return }
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.nameFieldStringValue = "\(project.name).wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        captureStates()
        exporting = true
        status = "Exporting \(url.lastPathComponent)…"
        let snapshot = project, bank = bank
        Task { [weak self] in
            // Own plugin instances: the live ones belong to the audio thread.
            let prepared = await OfflineRender.prepare(snapshot, bank: bank)
            guard prepared.endFrame > 0 else {
                self?.exporting = false
                self?.status = "Nothing to export: the arrangement and the Session launches are empty"
                return
            }
            let note = prepared.warnings.isEmpty ? "" : " (\(prepared.warnings.count) warning\(prepared.warnings.count == 1 ? "" : "s"): \(prepared.warnings[0]))"
            nonisolated(unsafe) let job = prepared
            let end = prepared.endFrame + Int64(2 * snapshot.sampleRate)
            let result: Result<Double, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let audio = withExtendedLifetime(job.host) { Bounce.render(job.plan, endFrame: end) }
                    try Bounce.writeWAV(audio, to: url)
                    return Double(audio.frames) / audio.sampleRate
                }
            }.value
            guard let self else { return }
            self.exporting = false
            switch result {
            case .success(let seconds): self.status = "Exported \(url.lastPathComponent), \(Int(seconds.rounded())) s\(note)"
            case .failure(let error): self.status = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func reset(to new: Project, at url: URL) {
        saveTask?.cancel()
        pause()
        if new.sampleRate != engine.sampleRate {
            // A project at another rate: the engine renders at its rate, so it plays at the right speed.
            do { try engine.setSampleRate(new.sampleRate) } catch { status = "Audio restart failed: \(error.localizedDescription)" }
            applyAudioSettings()
        }
        engine.seek(to: 0)
        project = new
        packageURL = url
        journal = try? Journal(url: url.appendingPathComponent("journal.jsonl"), durable: false)
        bank = AudioBank.live()
        warpTask?.cancel()
        host.removeAll()
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

    func newDemoProject() {
        save()
        createDemo()
    }

    private func createDemo() {
        DemoSamples.ensure()
        var name = "Demo Set"
        var n = 2
        let folder = Self.projectsFolder
        // An existing package is never replaced: a set with the same name gets a number.
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).loopstudio").path) { name = "Demo Set \(n)"; n += 1 }
        reset(to: Project(name: name), at: folder.appendingPathComponent("\(name).loopstudio"))

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
        // A MIDI track with Apple's synth: two chord loops, so scene 1 and 2 have an instrument too.
        func arpeggio(_ pitches: [UInt8]) -> Clip {
            let notes = (0..<8).map { i in MIDINote(tick: Tick(Int64(i) * 480), length: Tick(440), pitch: pitches[i % 4] + (i >= 4 ? 12 : 0), velocity: i % 2 == 0 ? 100 : 80) }
            return .midi(MIDIClip(start: 0, length: Tick(barTicks), loop: true, notes: notes))
        }
        var keys = Track(name: "Keys", kind: .midi, colorIndex: 7, volumeDb: 3, midiInput: MIDIInputSelection())
        keys.devices = [DeviceSlot(format: "audiounit", identifier: "aumu/dls /appl", name: "Apple DLS Synth")]
        keys.slots = [SessionSlot(clip: arpeggio([57, 60, 64, 67])), SessionSlot(clip: arpeggio([53, 57, 60, 65]))]
        try? Command.insertTrack(track: keys, index: project.tracks.count).apply(to: &project)

        // Two return tracks with effects, sends from Pad and Arp, a compressor on the drums, a limiter on the master.
        let reverbTrack = Track(name: "A Reverb", kind: .returnTrack, colorIndex: 4)
        let delayTrack = Track(name: "B Delay", kind: .returnTrack, colorIndex: 2)
        try? Command.insertTrack(track: reverbTrack, index: project.tracks.count).apply(to: &project)
        try? Command.insertTrack(track: delayTrack, index: project.tracks.count).apply(to: &project)
        var reverb = BuiltInEffects.makeSlot("reverb")!; reverb.params = ["mix": 1, "size": 0.8]
        var delay = BuiltInEffects.makeSlot("delay")!; delay.params = ["mix": 1, "timeMs": 375, "feedback": 0.45]
        try? Command.insertDevice(track: reverbTrack.id, device: reverb, index: nil).apply(to: &project)
        try? Command.insertDevice(track: delayTrack.id, device: delay, index: nil).apply(to: &project)
        try? Command.insertDevice(track: project.tracks[0].id, device: BuiltInEffects.makeSlot("compressor")!, index: nil).apply(to: &project)
        try? Command.insertDevice(track: project.master.id, device: BuiltInEffects.makeSlot("limiter")!, index: nil).apply(to: &project)
        for (i, level) in [(2, -8.0), (3, -14.0)] {
            let t = project.tracks[i]
            try? Command.setSends(id: t.id, sends: [Send(target: reverbTrack.id, levelDb: level), Send(target: delayTrack.id, levelDb: i == 3 ? -10 : -96)]).apply(to: &project)
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
        syncPlugins()
        save()
    }
}
