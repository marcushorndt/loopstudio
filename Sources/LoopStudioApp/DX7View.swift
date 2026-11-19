import LoopStudioCore
import LoopStudioEngine
import SwiftUI

private let dx7Tint = Color(red: 0.36, green: 0.78, blue: 0.62)
private let groupGap = DeviceLayout.groupGap

/// The DX7 panel. Left: the six operator buttons, lit by their envelopes. Top row: the display with the
/// voice name, the bank browser and the algorithm, then the voice and LFO knobs. Bottom row: the selected
/// operator, its envelope drawn and its knobs, or the key scaling and the pitch envelope.
struct DX7View: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    let spec: EffectSpec
    @State private var selected = 0
    @State private var page = Page.envelope
    @State private var browsing = false
    /// Where the browser last picked, so the arrows step through that bank.
    @State private var position: (bank: URL, voice: Int)?

    enum Page { case envelope, scaling }

    /// Finds the device's voice in the library, so the arrows step through its bank after a preset, a
    /// reopened project or a restart: the bank voice with the device's name whose values match, or the
    /// first with the name. Nothing found: the arrows stay off until the browser picks.
    private func resolvePosition() {
        guard model.dx7LibraryState == .loaded else { return }
        let name = device.name.trimmingCharacters(in: .whitespaces)
        if let p = position, let bank = model.dx7Banks.first(where: { $0.url == p.bank }),
           p.voice < bank.names.count, bank.names[p.voice].trimmingCharacters(in: .whitespaces) == name { return }
        func matches(_ voice: DX7.Voice) -> Bool {
            voice.params.allSatisfy { key, value in
                abs((device.params[key] ?? spec.param(key)?.def ?? 0) - value) < 0.5
            }
        }
        var byName: (bank: URL, voice: Int)?
        for bank in model.dx7Banks {
            for (i, n) in bank.names.enumerated() where n.trimmingCharacters(in: .whitespaces) == name {
                if byName == nil { byName = (bank.url, i) }
                if let voice = bank.voice(i), matches(voice) { position = (bank.url, i); return }
            }
        }
        position = byName
    }

    private func knob(_ key: String) -> some View { ParamKnob(track: track, device: device, spec: spec, key: key, tint: dx7Tint) }
    private func knob(_ op: Int, _ key: String) -> some View { knob(DX7.key(op + 1, key)) }

    var body: some View {
        HStack(alignment: .top, spacing: groupGap) {
            OperatorColumn(track: track, device: device, selected: $selected, page: $page)
            VStack(alignment: .leading, spacing: groupGap) {
                HStack(alignment: .top, spacing: groupGap) {
                    DX7Display(track: track, device: device, position: $position, browsing: $browsing)
                        .frame(width: 230, height: DeviceLayout.sectionHeight)
                    KnobSection(title: "Voice") { knob("alg"); knob("fb"); knob("oks"); knob("transpose"); knob("volume") }
                    KnobSection(title: "LFO") { knob("lfs"); knob("lfd"); knob("lfw"); knob("lfks"); knob("lpmd"); knob("lamd"); knob("lpms") }
                }
                HStack(alignment: .top, spacing: groupGap) {
                    switch page {
                    case .envelope:
                        DX7EnvelopeDisplay(device: device, op: selected)
                            .frame(width: 230, height: DeviceLayout.sectionHeight)
                        KnobSection(title: "Op \(selected + 1) · Envelope") {
                            ForEach(["r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4"], id: \.self) { knob(selected, $0) }
                        }
                        .id("env\(selected)")
                        KnobSection(title: "Op \(selected + 1) · Oscillator") {
                            ForEach(["mode", "coarse", "fine", "det", "ol", "kvs"], id: \.self) { knob(selected, $0) }
                        }
                        .id("osc\(selected)")
                        .hint("Ratio mode: Coarse 0 is half the key's pitch, 1 the pitch, 2 an octave up and so on; Fine adds up to 99 %. Fixed mode: 1, 10, 100 or 1000 Hz times the fine amount, whatever the key.")
                    case .scaling:
                        KnobSection(title: "Op \(selected + 1) · Key Scaling") {
                            ForEach(["bp", "ld", "rd", "lc", "rc", "rs", "ams"], id: \.self) { knob(selected, $0) }
                        }
                        .id("scale\(selected)")
                        .hint("Level scaling: from the break point (39 is C3) the level falls or rises to the left and the right along a curve. Rate scaling speeds the envelope up on high keys. Amp Mod Sens lets the LFO tremolo this operator.")
                        KnobSection(title: "Pitch Envelope") {
                            ForEach(["pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"], id: \.self) { knob($0) }
                        }
                        .hint("The pitch of the whole voice: four rates and four levels, 50 is the key's pitch, 99 four octaves up, 0 four down.")
                    }
                }
            }
        }
        .onAppear { model.loadDX7Library(); resolvePosition() }
        .onChange(of: model.dx7LibraryState) { _, _ in resolvePosition() }
        .onChange(of: device.name) { _, _ in resolvePosition() }
    }
}

// MARK: Operators

/// The six operator buttons: the number, a bar for the envelope level, dim when the operator is off.
/// A click selects, a double-click switches the operator on or off. The page switch sits under them.
private struct OperatorColumn: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    @Binding var selected: Int
    @Binding var page: DX7View.Page

    var body: some View {
        let synth = model.engine.builtInInstrument(device.id)
        let alg = DX7.algorithms[Int(device.params["alg"] ?? 0)]
        VStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: synth == nil)) { _ in
                let levels = (0..<6).map { Double(synth?.telemetryValue($0) ?? 0) }
                VStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { op in
                        button(op, level: levels[op], carrier: alg.isCarrier(op))
                    }
                }
            }
            Button {
                page = page == .envelope ? .scaling : .envelope
            } label: {
                Text(page == .envelope ? "KEYS" : "EG").font(.system(size: 8, weight: .semibold)).tracking(0.5)
                    .frame(width: 50, height: 16)
                    .background(RoundedRectangle(cornerRadius: Theme.radius + 1).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius + 1).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hint(page == .envelope ? "Show the key scaling of the operator and the pitch envelope" : "Show the operator's envelope and oscillator")
        }
        .padding(.top, 2)
    }

    private func button(_ op: Int, level: Double, carrier: Bool) -> some View {
        let on = (device.params[DX7.key(op + 1, "on")] ?? 1) >= 0.5
        return Button {
            selected = op
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text("OP\(op + 1)").font(.system(size: 9, weight: .semibold))
                    Text(carrier ? "C" : "M").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.dim)
                }
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.1)).frame(width: 36, height: 3)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(dx7Tint).frame(width: 36 * min(1, max(0, (level - 0.4) / 0.6)), height: 3)
                    }
            }
            .frame(width: 50, height: 24)
            .opacity(on ? 1 : 0.4)
            .background(RoundedRectangle(cornerRadius: Theme.radius + 1).fill(dx7Tint.opacity(on ? 0.1 + 0.4 * min(1, max(0, (level - 0.4) / 0.6)) : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 1).stroke(selected == op ? Theme.text : Theme.line, lineWidth: selected == op ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.setDeviceParam(track.id, device.id, DX7.key(op + 1, "on"), on ? 0 : 1)
        })
        .contextMenu {
            Button(on ? "Switch Operator \(op + 1) Off" : "Switch Operator \(op + 1) On") {
                model.setDeviceParam(track.id, device.id, DX7.key(op + 1, "on"), on ? 0 : 1)
            }
        }
        .hint("Operator \(op + 1), a \(carrier ? "carrier: it is heard" : "modulator: it shapes another operator"). Click to show its knobs, double-click to switch it \(on ? "off" : "on").")
    }
}

// MARK: Display

/// The voice name and its bank, arrows through the bank, the browser, and the algorithm drawn.
private struct DX7Display: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    @Binding var position: (bank: URL, voice: Int)?
    @Binding var browsing: Bool
    @State private var choosing = false

    private var bank: DX7BankEntry? { position.flatMap { p in model.dx7Banks.first { $0.url == p.bank } } }

    var body: some View {
        let alg = Int(device.params["alg"] ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button { step(-1, bank: NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.dx7Banks.isEmpty).hint("The voice before this one; past the first voice the bank before. Option-click: the bank before.")
                Button { browsing.toggle() } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                        Text(bank.map { "\($0.name) · \(position!.voice + 1)" } ?? "Click for the banks").font(.system(size: 8)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $browsing, arrowEdge: .bottom) {
                    DX7Browser(track: track, device: device, position: $position, shown: $browsing)
                }
                .hint("The voice. Click to browse every bank in the library.")
                Button { step(1, bank: NSEvent.modifierFlags.contains(.option)) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.dx7Banks.isEmpty).hint("The next voice; past the last voice the next bank. Option-click: the next bank.")
            }
            .padding(.horizontal, 6).padding(.top, 4)
            let fb = Int(device.params["fb"] ?? 0)
            AlgorithmGraph(algorithm: DX7.algorithms[alg], params: device.params)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    Text("ALG \(alg + 1) · FB \(fb)").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.dim).padding(4)
                }
                .contentShape(Rectangle())
                .onTapGesture { choosing = true }
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    DX7AlgorithmGrid(track: track, device: device, shown: $choosing)
                }
                .hint("Algorithm \(alg + 1): the operators and who modulates whom. Carriers stand on the bottom row; the wire with the arrow is the feedback (FB \(fb)). Click to pick one of the 32 from the grid.")
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
        .contextMenu {
            Button("Browse Banks…") { browsing = true }
            Button("Import Banks…") { model.importDX7Banks() }
            Button("Reveal Bank Folder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.dx7Folder]) }
            Divider()
            Button("Init Voice") { model.initDX7Voice(onto: device.id, on: track.id) }
            Button("Export Voice as SysEx…") { model.exportDX7Voice(device) }
        }
    }

    /// The next or previous voice, on through the library: past the end of a bank the neighbouring bank.
    /// With `bank`, the first voice of the neighbouring bank. Without a position, the library's first voice.
    private func step(_ by: Int, bank byBank: Bool) {
        let banks = model.dx7Banks
        guard !banks.isEmpty else { return }
        var b: Int, v: Int
        if let p = position, let known = banks.firstIndex(where: { $0.url == p.bank }) {
            b = known
            v = p.voice
            if byBank {
                b = (b + by + banks.count) % banks.count
                v = 0
            } else {
                v += by
                if v < 0 { b = (b - 1 + banks.count) % banks.count; v = max(0, banks[b].names.count - 1) }
                if v >= banks[b].names.count { b = (b + 1) % banks.count; v = 0 }
            }
        } else {
            // Nothing known yet: forward starts at the library's first voice, back at its last.
            b = by > 0 ? 0 : banks.count - 1
            v = by > 0 ? 0 : max(0, banks[b].names.count - 1)
        }
        guard b >= 0, b < banks.count, let voice = banks[b].voice(v) else { return }
        position = (banks[b].url, v)
        model.loadDX7Voice(voice, onto: device.id, on: track.id)
    }
}

/// The algorithm as the panel print: carriers along the bottom, each modulator above what it drives, the
/// feedback as a loop. An operator with a level of zero or switched off is drawn faint.
private struct AlgorithmGraph: View {
    let algorithm: DX7.Algorithm
    /// The device's values: an operator at level zero or switched off is drawn faint. Empty: nothing is faint.
    let params: [String: Double]
    /// Small, for the grid of all 32: tighter margins, smaller boxes.
    var compact = false

    /// Columns and rows for the six operators: a tree under every carrier, left to right.
    static func layout(_ alg: DX7.Algorithm) -> (positions: [Int: (x: Double, y: Int)], width: Double, depth: Int) {
        var owner = [Int: Int]()
        for op in 0..<6 where !alg.isCarrier(op) {
            if let first = alg.targets(of: op).min() { owner[op] = first }
        }
        func children(_ op: Int) -> [Int] { (0..<6).filter { owner[$0] == op }.sorted(by: >) }
        func width(_ op: Int) -> Double { max(1, children(op).reduce(0) { $0 + width($1) }) }
        var positions: [Int: (x: Double, y: Int)] = [:]
        var depth = 0
        func place(_ op: Int, left: Double, y: Int) {
            let w = width(op)
            positions[op] = (left + w / 2, y)
            depth = max(depth, y)
            var x = left
            for c in children(op) { place(c, left: x, y: y + 1); x += width(c) }
        }
        var x = 0.0
        for c in alg.carriers.sorted() { place(c, left: x, y: 0); x += width(c) }
        return (positions, x, depth)
    }

    var body: some View {
        Canvas { ctx, size in
            let (positions, columns, depth) = Self.layout(algorithm)
            let rows = Double(depth + 1)
            let margin = compact ? 6.0 : 24.0
            let cellW = min(34, (size.width - margin) / columns), cellH = min(16, (size.height - 6) / rows)
            let boxW = min(20, cellW - 2), boxH = min(12, cellH - 3)
            let originX = (size.width - cellW * columns) / 2
            func point(_ op: Int) -> CGPoint {
                let p = positions[op]!
                return CGPoint(x: originX + p.x * cellW, y: size.height - 4 - cellH * (Double(p.y) + 0.5))
            }
            func faint(_ op: Int) -> Bool {
                !params.isEmpty && ((params[DX7.key(op + 1, "on")] ?? 1) < 0.5 || (params[DX7.key(op + 1, "ol")] ?? 0) < 1)
            }
            // The wires: modulator to carrier, straight down.
            for op in 0..<6 {
                for t in algorithm.targets(of: op) {
                    var path = Path()
                    path.move(to: point(op)); path.addLine(to: point(t))
                    ctx.stroke(path, with: .color(dx7Tint.opacity(faint(op) ? 0.25 : 0.7)), lineWidth: 1)
                }
            }
            // The feedback, as on the panel print: a wire leaves the source at its right, climbs above the
            // target and comes down into the target's top. Strong while FB is above zero, faint at zero.
            let from = point(algorithm.feedbackFrom), to = point(algorithm.feedbackTo)
            let out = boxW / 2 + (compact ? 3 : 6)
            let above = min(to.y, from.y) - boxH / 2 - (compact ? 3 : 5)
            var loop = Path()
            loop.move(to: CGPoint(x: from.x + boxW / 2, y: from.y))
            loop.addLine(to: CGPoint(x: from.x + out, y: from.y))
            loop.addLine(to: CGPoint(x: from.x + out, y: above))
            loop.addLine(to: CGPoint(x: to.x, y: above))
            loop.addLine(to: CGPoint(x: to.x, y: to.y - boxH / 2))
            let fb = params["fb"] ?? (params.isEmpty ? 7 : 0)
            let fbColor = dx7Tint.opacity(fb > 0 ? 0.9 : 0.3)
            ctx.stroke(loop, with: .color(fbColor), style: StrokeStyle(lineWidth: fb > 0 ? 1.2 : 1, dash: fb > 0 ? [] : [2, 2]))
            // The arrow head where the wire enters the target.
            var head = Path()
            let tip = CGPoint(x: to.x, y: to.y - boxH / 2)
            head.move(to: CGPoint(x: tip.x - 2.5, y: tip.y - 3.5)); head.addLine(to: tip); head.addLine(to: CGPoint(x: tip.x + 2.5, y: tip.y - 3.5))
            ctx.stroke(head, with: .color(fbColor), lineWidth: 1)
            if !compact {
                ctx.draw(Text("FB").font(.system(size: 6, weight: .semibold)).foregroundStyle(fbColor),
                         at: CGPoint(x: from.x + out + 2, y: (from.y + above) / 2), anchor: .leading)
            }
            // The boxes.
            for op in 0..<6 {
                let c = point(op)
                let rect = CGRect(x: c.x - boxW / 2, y: c.y - boxH / 2, width: boxW, height: boxH)
                let carrier = algorithm.isCarrier(op)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(carrier ? dx7Tint.opacity(faint(op) ? 0.2 : 0.75) : Color.white.opacity(faint(op) ? 0.06 : 0.16)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(dx7Tint.opacity(faint(op) ? 0.3 : 0.9)), lineWidth: 1)
                ctx.draw(Text("\(op + 1)").font(.system(size: boxH * 0.66, weight: .bold)).foregroundStyle(carrier && !faint(op) ? .black : Theme.text), at: c)
            }
        }
    }
}

/// The 32 algorithms as on the DX7's panel: a grid to tap. The current one is framed.
private struct DX7AlgorithmGrid: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    @Binding var shown: Bool

    var body: some View {
        let current = Int(device.params["alg"] ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            Text("Algorithm").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 4), count: 8), spacing: 4) {
                ForEach(0..<32, id: \.self) { i in
                    Button {
                        model.setDeviceParam(track.id, device.id, "alg", Double(i))
                        shown = false
                    } label: {
                        AlgorithmGraph(algorithm: DX7.algorithms[i], params: [:], compact: true)
                            .frame(width: 78, height: 60)
                            .overlay(alignment: .topLeading) {
                                Text("\(i + 1)").font(.system(size: 8, weight: .semibold)).foregroundStyle(i == current ? dx7Tint : Theme.dim).padding(3)
                            }
                            .background(Color.black.opacity(i == current ? 0.4 : 0.2), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == current ? dx7Tint : Theme.line.opacity(0.5), lineWidth: i == current ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .hint("Algorithm \(i + 1)")
                }
            }
            Text("Carriers on the bottom row, modulators above them, the arrow is the feedback.").font(.system(size: 9)).foregroundStyle(Theme.dim)
        }
        .padding(10)
    }
}

// MARK: Envelope

/// The envelope of one operator: the four segments drawn from the rates and levels, the live level as a
/// line that moves. Rates count down, so a slow segment is a long one.
private struct DX7EnvelopeDisplay: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSlot
    let op: Int

    var body: some View {
        let synth = model.engine.builtInInstrument(device.id)
        let k = { (n: String) in DX7.key(op + 1, n) }
        let rates = (1...4).map { device.params[k("r\($0)")] ?? 99 }
        let levels = (1...4).map { device.params[k("l\($0)")] ?? 0 }
        let ol = device.params[k("ol")] ?? 0
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: synth == nil)) { _ in
            let live = Double(synth?.telemetryValue(op) ?? 0)
            Canvas { ctx, size in
                let plot = CGRect(x: 8, y: 10, width: size.width - 16, height: size.height - 24)
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.black.opacity(0.25)))
                // Segment widths: a slow rate is wide. The sustain (after L3) gets a fixed stretch.
                let widths = rates.map { 12 + (100 - $0) * 1.6 }
                let sustain = 40.0
                let total = widths[0] + widths[1] + widths[2] + sustain + widths[3]
                func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat(t / total) }
                func y(_ level: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(level / 99) }
                var path = Path()
                var t = 0.0
                path.move(to: CGPoint(x: x(0), y: y(levels[3])))
                for i in 0..<3 { t += widths[i]; path.addLine(to: CGPoint(x: x(t), y: y(levels[i]))) }
                t += sustain; path.addLine(to: CGPoint(x: x(t), y: y(levels[2])))
                t += widths[3]; path.addLine(to: CGPoint(x: x(t), y: y(levels[3])))
                var fill = path
                fill.addLine(to: CGPoint(x: x(total), y: plot.maxY)); fill.addLine(to: CGPoint(x: x(0), y: plot.maxY)); fill.closeSubpath()
                ctx.fill(fill, with: .color(dx7Tint.opacity(0.12)))
                ctx.stroke(path, with: .color(dx7Tint.opacity(0.9)), lineWidth: 1.5)
                // The key-up mark.
                let up = x(widths[0] + widths[1] + widths[2] + sustain)
                var dash = Path(); dash.move(to: CGPoint(x: up, y: plot.minY)); dash.addLine(to: CGPoint(x: up, y: plot.maxY))
                ctx.stroke(dash, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                // The live level: the telemetry is the log level over 16 octaves; the 99 line sits at 15.
                if live > 0.05 {
                    let ly = plot.maxY - plot.height * CGFloat(min(1, live * 16 / 15))
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: ly)); line.addLine(to: CGPoint(x: plot.maxX, y: ly))
                    ctx.stroke(line, with: .color(Theme.automationDot.opacity(0.8)), lineWidth: 1)
                }
                let labels = ["R1", "R2", "R3", "", "R4"]
                var lx = 0.0
                for (i, w) in (widths[0..<3] + [sustain] + [widths[3]]).enumerated() {
                    if !labels[i].isEmpty {
                        ctx.draw(Text(labels[i]).font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.dim), at: CGPoint(x: x(lx + w / 2), y: size.height - 6))
                    }
                    lx += w
                }
                ctx.draw(Text("OP\(op + 1) · OL \(Int(ol))").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.dim), at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
            }
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.7), lineWidth: 1))
        .hint("Operator \(op + 1)'s envelope: the four rates and levels. The red line is the level as it sounds.")
    }
}

// MARK: Browser

/// Every voice of every bank in the library, searched by name. A click plays the voice on the device.
private struct DX7Browser: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let device: DeviceSlot
    @Binding var position: (bank: URL, voice: Int)?
    @Binding var shown: Bool
    @State private var query = ""

    private struct Hit: Identifiable {
        var bank: DX7BankEntry
        var voice: Int
        var id: String { bank.url.path + "#\(voice)" }
        var name: String { bank.names[voice] }
    }

    private var hits: [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var out: [Hit] = []
        for bank in model.dx7Banks {
            let bankName = bank.name.lowercased()
            for (i, name) in bank.names.enumerated() {
                let text = name.lowercased()
                if words.allSatisfy({ text.contains($0) || bankName.contains($0) }) {
                    out.append(Hit(bank: bank, voice: i))
                    if out.count >= 400 { return out }
                }
            }
        }
        return out
    }

    var body: some View {
        let banks = model.dx7Banks
        let voices = banks.count * 32
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search voices and banks", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
                // The open panel is a modal window: the popover closes first, or AppKit throws when the two meet.
                Button("Import…") {
                    shown = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.importDX7Banks() }
                }
                .hint("Copy .syx bank files or folders of them into the library")
            }
            if model.dx7LibraryState == .loading {
                Text("Reading the banks…").font(.system(size: 11)).foregroundStyle(Theme.dim)
            } else if banks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No banks yet.").font(.system(size: 12, weight: .semibold))
                    Text("Import 32-voice SysEx files (.syx), or drop them into the folder.").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Button("Reveal Bank Folder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.dx7Folder]) }
                }
                .padding(.vertical, 8)
            } else {
                let list = hits
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { hit in
                            Button {
                                guard let voice = hit.bank.voice(hit.voice) else { return }
                                position = (hit.bank.url, hit.voice)
                                model.loadDX7Voice(voice, onto: device.id, on: track.id)
                            } label: {
                                HStack {
                                    Text(hit.name.isEmpty ? "(no name)" : hit.name).font(.system(size: 12, design: .monospaced))
                                    Spacer()
                                    Text("\(hit.bank.name) · \(hit.voice + 1)").font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                                }
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(position?.bank == hit.bank.url && position?.voice == hit.voice ? dx7Tint.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 320)
                HStack {
                    Text(list.count >= 400 ? "First 400 of many: type more" : "\(list.count) voice\(list.count == 1 ? "" : "s")")
                    Spacer()
                    Text("\(banks.count) banks · \(voices) voices").foregroundStyle(Theme.dim)
                }
                .font(.system(size: 10))
            }
        }
        .padding(10)
        .frame(width: 440)
    }
}
