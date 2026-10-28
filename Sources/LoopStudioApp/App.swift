import AppKit
import LoopStudioCore
import SwiftUI

@main
struct LoopStudioApp: App {
    @State private var project = DemoProject.make()

    init() {
        // Started from the shell (not a bundle), the app needs this to get a menu bar and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("LoopStudio") {
            ProjectView(project: project)
                .frame(minWidth: 900, minHeight: 520)
        }
    }
}

private let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .blue, .indigo, .purple, .pink, .teal]
func color(_ index: Int) -> Color { palette[index % palette.count] }

struct ProjectView: View {
    let project: Project
    @State private var bars = 16

    private var simulation: SessionSimulation {
        SessionSimulator.run(project, horizon: Tick(Int64(bars) * 4 * Tick.perQuarter))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                SessionGrid(project: project).frame(minWidth: 320, idealWidth: 380)
                TimelineView(project: project, simulation: simulation, bars: bars).frame(minWidth: 500)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(project.name).font(.headline)
            Text("seed \(project.randomSeed)").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Stepper("\(bars) bars", value: $bars, in: 4...64, step: 4)
        }
        .padding(8)
    }
}

/// Session slots: one column per track, one row per scene. Follow actions show as "A/B" chips.
struct SessionGrid: View {
    let project: Project

    var body: some View {
        let rows = project.tracks.map(\.slots.count).max() ?? 0
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ForEach(project.tracks, id: \.id) { track in
                        Text(track.name).font(.caption.bold()).frame(width: 150, alignment: .leading)
                    }
                }
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(project.tracks, id: \.id) { track in
                            if row < track.slots.count, let slot = track.slots[row] {
                                SlotCell(slot: slot, tint: color(track.colorIndex))
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)).frame(width: 150, height: 44)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

struct SlotCell: View {
    let slot: SessionSlot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(slot.clip.length.rawValue / (4 * Tick.perQuarter)) bar").font(.caption2)
            if let f = slot.follow {
                Text("\(f.a.kind.rawValue) \(Int(f.a.weight)) / \(f.b.kind.rawValue) \(Int(f.b.weight)) · \(f.time.amount)×")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(width: 150, height: 44, alignment: .leading)
        .background(tint.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Timeline: arrangement clips plus what the session simulator says plays when.
struct TimelineView: View {
    let project: Project
    let simulation: SessionSimulation
    let bars: Int

    private let laneHeight: CGFloat = 54
    private let nameWidth: CGFloat = 70

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - nameWidth)
            let ticks = Double(Int64(bars) * 4 * Tick.perQuarter)
            VStack(alignment: .leading, spacing: 0) {
                ruler(width: width)
                ForEach(project.tracks, id: \.id) { track in
                    HStack(spacing: 0) {
                        Text(track.name).font(.caption).frame(width: nameWidth, alignment: .leading).padding(.leading, 6)
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.quaternary.opacity(0.25))
                            ForEach(track.clips, id: \.id) { clip in
                                block(Double(clip.start.rawValue), Double(clip.length.rawValue), ticks, width, color(track.colorIndex), nil)
                            }
                            ForEach(Array(simulation.events.filter { $0.track == track.id }.enumerated()), id: \.offset) { _, e in
                                block(Double(e.startTick.rawValue), Double((e.endTick - e.startTick).rawValue), ticks, width,
                                      color(track.colorIndex), "\(e.slot + 1)\(e.cause == .follow ? "·f" : "")")
                            }
                        }
                        .frame(width: width, height: laneHeight)
                    }
                    Divider()
                }
                if !simulation.warnings.isEmpty {
                    Text(simulation.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).padding(8)
                }
                Spacer()
            }
        }
    }

    private func block(_ start: Double, _ length: Double, _ total: Double, _ width: Double, _ tint: Color, _ label: String?) -> some View {
        let x = start / total * width
        let w = max(2, length / total * width - 1)
        return RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(label == nil ? 0.30 : 0.75))
            .overlay(alignment: .leading) { if let label { Text(label).font(.system(size: 10).bold()).padding(.leading, 4) } }
            .frame(width: w, height: label == nil ? laneHeight - 28 : laneHeight - 8)
            .offset(x: x, y: label == nil ? 22 : 4)
    }

    private func ruler(width: Double) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: nameWidth)
            ZStack(alignment: .topLeading) {
                ForEach(0..<bars, id: \.self) { bar in
                    Text("\(bar + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                        .offset(x: Double(bar) / Double(bars) * width + 2)
                }
            }
            .frame(width: width, height: 16)
        }
        .padding(.vertical, 2)
    }
}
