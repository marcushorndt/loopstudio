import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// dB to meter position: -60 dB at the bottom, +6 dB at the top.
func meterPosition(linear: Float) -> Double {
    guard linear > 0.000_001 else { return 0 }
    return min(1, max(0, (20 * log10(Double(linear)) + 60) / 66))
}

struct LevelBar: View {
    let level: Float
    var horizontal = false

    var body: some View {
        GeometryReader { geo in
            let p = meterPosition(linear: level)
            ZStack(alignment: horizontal ? .leading : .bottom) {
                Rectangle().fill(Color.black.opacity(0.5))
                Rectangle()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: horizontal ? .leading : .bottom,
                                         endPoint: horizontal ? .trailing : .top))
                    .frame(width: horizontal ? geo.size.width * p : nil, height: horizontal ? nil : geo.size.height * p)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Vertical fader. The scale puts 0 dB at 71 % of the travel and +6 dB at the top.
struct Fader: View {
    let db: Double
    let onChange: (Double) -> Void

    static func position(db: Double) -> Double { min(1, max(0, (pow(10, db / 20) / 2).squareRoot())) }
    static func db(position p: Double) -> Double { p <= 0.003 ? -96 : 20 * log10(p * p * 2) }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let y = h * (1 - Self.position(db: db))
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 4).frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Theme.text.opacity(0.95), Theme.text.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(.black.opacity(0.7)).frame(height: 1))
                    .frame(width: 26, height: 14)
                    .offset(y: min(max(0, y - 7), h - 14))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Self.db(position: 1 - min(max(0, g.location.y / h), 1)))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
    }
}

/// A mixer strip: pan, fader with meter, and the mute and solo buttons.
struct MixerStrip: View {
    /// Room for Audio From, the monitor buttons and Audio To.
    static let ioHeight: CGFloat = 92
    /// The send knobs: rows of four, each 42 points high.
    /// Three 36 pt knobs fit the 128 pt strip with its padding; a fourth would cover the next strip.
    static let sendsPerRow = 3
    static func sendsHeight(_ returns: Int) -> CGFloat {
        returns == 0 ? 0 : CGFloat((returns + sendsPerRow - 1) / sendsPerRow) * 46 - 4
    }
    @Environment(AppModel.self) private var model
    let track: Track
    let isMaster: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            Slider(value: Binding(get: { track.pan }, set: { model.apply(.setPan(id: track.id, pan: $0), key: "pan\(track.id)") }), in: -1...1)
                .controlSize(.mini)
                .contextMenu { Button("Center") { model.apply(.setPan(id: track.id, pan: 0)) } }
                .hint("Pan")

            // Every strip has the same rows at the same heights, so faders line up across the mixer.
            let returns = model.project.tracks.filter { $0.kind == .returnTrack }
            // The sends as knobs, like Live: one per return track, three to a row.
            HStack(alignment: .top, spacing: 0) {
                if !isMaster && track.kind != .returnTrack {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: min(Self.sendsPerRow, max(1, returns.count))),
                              alignment: .leading, spacing: 4) {
                        ForEach(returns, id: \.id) { ret in SendKnob(track: track, ret: ret) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.sendsHeight(returns.count), alignment: .top)

            Group {
                if isMaster {
                    Text("Master").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                } else {
                    TrackIOSection(track: track)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.ioHeight, alignment: .top)

            HStack(spacing: 6) {
                Fader(db: track.volumeDb) { model.apply(.setVolume(id: track.id, db: $0), key: "vol\(track.id)") }
                    .frame(width: 44, height: 100)
                    .hint("\(track.name) volume: \(track.volumeDb <= -90 ? "-inf" : String(format: "%.1f dB", track.volumeDb)). Drag; double-click sets 0 dB.")
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LevelBar(level: model.meterLevel(track: isMaster ? nil : track.id)).frame(width: 9, height: 100)
                }
            }

            Text(track.volumeDb <= -90 ? "-inf" : String(format: "%.1f dB", track.volumeDb))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)

            HStack(spacing: 4) {
                if !isMaster {
                    toggle("S", on: track.solo, tint: Theme.track(5)) {
                        model.toggleSolo(track)
                    }
                    .hint("Solo this track only. ⌘-click adds it to the soloed tracks.")
                    toggle("M", on: track.mute, tint: Theme.accent) {
                        model.apply(.setMute(id: track.id, mute: !track.mute))
                    }
                    if track.kind == .audio || track.kind == .midi {
                        toggle("●", on: model.armedTrack == track.id, tint: .red) { model.toggleArm(track.id) }
                            .hint("Arm: this track records and plays the MIDI keyboard, whatever is selected")
                    }
                }
            }
            .frame(height: 22)
        }
        .padding(6)
        .frame(width: width)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(model.selectedTrack == track.id ? Theme.text.opacity(0.35) : Theme.line, lineWidth: 1))
        .onTapGesture { model.focusTrack(track.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTrackInspector(track.id) })
        .contextMenu {
            Button("Reset Volume to 0 dB") { model.apply(.setVolume(id: track.id, db: 0)) }
            Button("Center Pan") { model.apply(.setPan(id: track.id, pan: 0)) }
            Divider()
            Button(model.isLaneShown(track, ParameterAddress(node: track.id.rawValue, parameter: "volume")) ? "Hide Volume Automation" : "Show Volume Automation") {
                model.toggleLaneAndReveal(track, ParameterAddress(node: track.id.rawValue, parameter: "volume"))
            }
            Button(model.isLaneShown(track, ParameterAddress(node: track.id.rawValue, parameter: "pan")) ? "Hide Pan Automation" : "Show Pan Automation") {
                model.toggleLaneAndReveal(track, ParameterAddress(node: track.id.rawValue, parameter: "pan"))
            }
            Divider()
            if !isMaster { TrackMenuItems(track: track) }
        }
        .dropDestination(for: String.self) { items, _ in drop(items) }
    }

    private func drop(_ items: [String]) -> Bool {
        return model.dropDevices(items, on: track.id)
    }

    /// For mute, the lit state means "audible", as in Live (the activator).
    private func toggle(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold)).frame(width: 34, height: 22)
                .foregroundStyle(on ? tint : Theme.dim)
                .background(on ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(on ? tint.opacity(0.55) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// One send as a small knob in the colour of its return track. Drag up or down; double-click turns it off.
struct SendKnob: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let ret: Track
    @State private var start: Double?

    /// -48 dB to 0 dB over the knob; the bottom is off.
    private var position: Double { (model.sendLevel(track, to: ret.id) + 48) / 48 }
    private var address: ParameterAddress { ParameterAddress(node: track.id.rawValue, parameter: "send.\(ret.id.rawValue.uuidString)") }

    private func set(_ p: Double) {
        let q = min(max(p, 0), 1)
        model.setSend(from: track, to: ret.id, db: q <= 0.01 ? -96 : -48 + 48 * q)
    }

    var body: some View {
        let db = model.sendLevel(track, to: ret.id)
        VStack(spacing: 1) {
            KnobDial(position: max(0, min(1, position)), tint: Theme.track(ret.colorIndex), lineWidth: 3)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil { start = max(0, min(1, position)) }
                        set((start ?? 0) - Double(g.translation.height) / 140)
                    }
                    .onEnded { _ in start = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { set(0) })
            Text(start != nil ? (db <= -47.5 ? "-inf" : String(format: "%.0f", db)) : String(ret.name.prefix(1)))
                .font(.system(size: 9, weight: .bold, design: start != nil ? .monospaced : .default))
                .foregroundStyle(start != nil ? Theme.text : Theme.track(ret.colorIndex))
                .lineLimit(1)
        }
        .frame(width: 36)
        .hint("Send to \(ret.name): \(db <= -47.5 ? "off" : String(format: "%.1f dB", db))")
        .contextMenu {
            Button("Send Off") { set(0) }
            Button("Send at 0 dB") { set(1) }
            Toggle("Pre-Fader", isOn: Binding(get: { model.sendPreFader(track, to: ret.id) },
                                              set: { model.setSendPreFader(from: track, to: ret.id, $0) }))
            Divider()
            Button(model.isLaneShown(track, address) ? "Hide Send Automation" : "Show Send Automation") {
                // A lane needs a send to automate: an untouched knob gets one, still off.
                if !track.sends.contains(where: { $0.target == ret.id }) { model.setSend(from: track, to: ret.id, db: -96) }
                if let fresh = model.project.track(track.id) { model.toggleLaneAndReveal(fresh, address) }
            }
        }
    }
}

/// Inputs and outputs of a track, like the I/O section in Live.
struct TrackIOSection: View {
    @Environment(AppModel.self) private var model
    let track: Track

    private enum Out: Hashable { case master, sendsOnly, track(TrackID), port(PortID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if track.kind == .audio { audioFrom }
            if track.kind == .midi { midiFrom }
            label("Audio To")
            outputPicker
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
    }

    @ViewBuilder private var audioFrom: some View {
        label("Audio From")
        Picker("", selection: Binding(get: { track.inputTrack }, set: { model.apply(.setInputTrack(id: track.id, source: $0)) })) {
            Text("Ext. In").tag(TrackID?.none)
            Divider()
            ForEach(model.project.tracks.filter { $0.id != track.id && $0.kind != .returnTrack }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden().controlSize(.mini).hint("Ext. In records the sound card input (Settings). A track records that track's sound.")
        if track.inputTrack != nil {
            HStack(spacing: 2) {
                ForEach([(MonitorMode.input, "In"), (.auto, "Auto"), (.off, "Off")], id: \.1) { mode, name in
                    Button { model.apply(.setMonitor(id: track.id, mode: mode)) } label: {
                        Text(name).font(.system(size: 9, weight: .bold)).frame(maxWidth: .infinity, minHeight: 16)
                            .foregroundStyle(track.monitorMode == mode ? .black : Theme.dim)
                            .background(track.monitorMode == mode ? Theme.accent : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .hint("Monitor. In and Auto pass the input. Off mutes it.")
        }
    }

    @ViewBuilder private var midiFrom: some View {
        label("MIDI From")
        let sources = MIDIEndpointCatalog.sources()
        Picker("", selection: Binding(
            get: { track.midiInput?.sourceUID.map { Optional($0) } ?? (track.midiInput == nil ? Int32?.none : Int32?.some(Int32.min)) },
            set: { choice in
                if let choice, choice != Int32.min {
                    let name = sources.first { $0.uniqueID == choice }?.name
                    model.apply(.setMIDIInput(id: track.id, selection: MIDIInputSelection(sourceUID: choice, sourceName: name, channel: track.midiInput?.channel)))
                } else if choice == Int32.min {
                    model.apply(.setMIDIInput(id: track.id, selection: MIDIInputSelection(channel: track.midiInput?.channel)))
                } else {
                    model.apply(.setMIDIInput(id: track.id, selection: nil))
                }
            })) {
            Text("All Ins").tag(Optional(Int32.min))
            ForEach(sources, id: \.uniqueID) { Text($0.name).tag(Optional($0.uniqueID)) }
            Divider()
            Text("No Input").tag(Int32?.none)
        }
        .labelsHidden().controlSize(.mini)
        if let input = track.midiInput {
            Picker("", selection: Binding(get: { input.channel.map { Int($0) } ?? -1 },
                                          set: { model.apply(.setMIDIInput(id: track.id, selection: MIDIInputSelection(sourceUID: input.sourceUID, sourceName: input.sourceName, channel: $0 < 0 ? nil : UInt8($0)))) })) {
                Text("All Channels").tag(-1)
                ForEach(0..<16, id: \.self) { Text("Ch \($0 + 1)").tag($0) }
            }
            .labelsHidden().controlSize(.mini)
        }
    }

    private var outputPicker: some View {
        let options = model.project.tracks.filter { ($0.kind == .group || $0.kind == .returnTrack) && $0.id != track.id }
        let current: Out = track.isSendsOnly ? .sendsOnly
            : track.hardwareOutput.map { .port($0) } ?? (track.output.map { .track($0) } ?? .master)
        // Leaving a direct output clears it first: a track goes to one place only.
        let clearPort: [Command] = track.hardwareOutput == nil ? [] : [.setHardwareOutput(id: track.id, port: nil)]
        return Picker("", selection: Binding(get: { current }, set: { choice in
            switch choice {
            case .master: model.apply(.batch(commands: clearPort + [.setSendsOnly(id: track.id, sendsOnly: false), .setOutput(id: track.id, target: nil)]))
            case .sendsOnly: model.apply(.batch(commands: clearPort + [.setSendsOnly(id: track.id, sendsOnly: true)]))
            case .track(let id): model.apply(.batch(commands: clearPort + [.setSendsOnly(id: track.id, sendsOnly: false), .setOutput(id: track.id, target: id)]))
            case .port(let id): model.apply(.batch(commands: [.setSendsOnly(id: track.id, sendsOnly: false), .setOutput(id: track.id, target: nil),
                                                              .setHardwareOutput(id: track.id, port: id)]))
            }
        })) {
            Text("Master").tag(Out.master)
            ForEach(options, id: \.id) { Text($0.name).tag(Out.track($0.id)) }
            if !model.assignablePorts.isEmpty {
                Divider()
                ForEach(model.assignablePorts, id: \.id) { Text("Ext. Out: \($0.name)").tag(Out.port($0.id)) }
            }
            Divider()
            Text("Sends Only").tag(Out.sendsOnly)
        }
        .labelsHidden().controlSize(.mini).hint("Output routing")
    }
}
