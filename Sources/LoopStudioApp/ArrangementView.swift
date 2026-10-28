import LoopStudioCore
import SwiftUI

private let laneHeight: CGFloat = 74
private let headerWidth: CGFloat = 176
private let rulerHeight: CGFloat = 28

struct ArrangementView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracks = model.project.tracks
        let bars = totalBars
        let width = CGFloat(Double(bars) * model.pixelsPerBar)

        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.dim)
                        Slider(value: Bindable(model).pixelsPerBar, in: 24...420).controlSize(.mini)
                    }
                    .padding(.horizontal, 8).frame(height: rulerHeight)
                    ForEach(tracks, id: \.id) { ArrangementHeader(track: $0) }
                    Button { model.addTrack() } label: { Label("Add track", systemImage: "plus").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).frame(height: 36)
                }
                .frame(width: headerWidth)

                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Ruler(bars: bars).frame(width: width, height: rulerHeight)
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                Lane(track: track, index: index, count: tracks.count, width: width)
                            }
                        }
                        LoopBrace(width: width)
                        Playhead(height: rulerHeight + laneHeight * CGFloat(max(1, tracks.count)))
                    }
                    .frame(width: width, alignment: .topLeading)
                }
            }
        }
        .background(Theme.background)
    }

    private var totalBars: Int {
        var end: Int64 = 0
        for t in model.project.tracks { for c in t.clips { end = max(end, (c.start + c.length).rawValue) } }
        let bars = Int(end / max(1, model.barTicks)) + 16
        return max(48, bars)
    }
}

@MainActor func tickX(_ tick: Tick, _ model: AppModel) -> CGFloat {
    CGFloat(Double(tick.rawValue) / Double(model.barTicks) * model.pixelsPerBar)
}

@MainActor func xTick(_ x: CGFloat, _ model: AppModel) -> Tick {
    Tick(Int64(max(0, Double(x) / model.pixelsPerBar * Double(model.barTicks))))
}

private struct ArrangementHeader: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.track(track.colorIndex)).frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    pill("S", on: track.solo, tint: Color(red: 0.4, green: 0.65, blue: 1)) { model.apply(.setSolo(id: track.id, solo: !track.solo)) }
                    pill("M", on: track.mute, tint: Theme.accent) { model.apply(.setMute(id: track.id, mute: !track.mute)) }
                }
            }
            Spacer()
        }
        .padding(6).frame(height: laneHeight)
        .background(model.selectedTrack == track.id ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onTapGesture { model.selectedTrack = track.id }
    }

    private func pill(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 18)
                .foregroundStyle(on ? .black : Theme.dim)
                .background(on ? tint : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

private struct Ruler: View {
    @Environment(AppModel.self) private var model
    let bars: Int

    var body: some View {
        Canvas { ctx, size in
            let ppb = model.pixelsPerBar
            let every = ppb < 40 ? 4 : (ppb < 70 ? 2 : 1)
            for bar in 0..<bars where bar % every == 0 {
                let x = CGFloat(Double(bar) * ppb)
                ctx.fill(Path(CGRect(x: x, y: size.height - 10, width: 1, height: 10)), with: .color(Theme.dim))
                ctx.draw(Text("\(bar + 1)").font(.system(size: 10)).foregroundStyle(Theme.dim), at: CGPoint(x: x + 4, y: 8), anchor: .leading)
            }
        }
        .background(Theme.panel)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: xTick($0.location.x, model)) })
    }
}

private struct Lane: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let index: Int
    let count: Int
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let ppb = model.pixelsPerBar
                var bar = 0
                while CGFloat(Double(bar) * ppb) < size.width {
                    let x = CGFloat(Double(bar) * ppb)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.10)))
                    if ppb > 140 {
                        for beat in 1..<4 {
                            ctx.fill(Path(CGRect(x: x + CGFloat(Double(beat) * ppb / 4), y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.04)))
                        }
                    }
                    bar += 1
                }
            }
            ForEach(track.clips, id: \.id) { clip in
                ArrangementClip(clip: clip, track: track, trackIndex: index, trackCount: count)
            }
        }
        .frame(width: width, height: laneHeight)
        .background(index % 2 == 0 ? Theme.background : Color(white: 0.145))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTrack = track.id }
        .dropDestination(for: URL.self) { urls, location in
            model.dropOnTimeline(urls, track: track.id, at: xTick(location.x, model))
        }
    }
}

private struct ArrangementClip: View {
    @Environment(AppModel.self) private var model
    let clip: Clip
    let track: Track
    let trackIndex: Int
    let trackCount: Int
    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0

    var body: some View {
        let tint = Theme.track(track.colorIndex)
        let x = tickX(clip.start, model)
        let w = max(6, tickX(clip.length, model) + resize)
        let selected = model.selectedClip == clip.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.75))
            if case .audio(let a) = clip, let peaks = model.waveforms[a.asset], let asset = model.project.asset(a.asset) {
                let assetTicks = Double(asset.frames) / max(1, asset.sampleRate) * model.bpm / 60 * Double(Tick.perQuarter)
                WaveformView(peaks: peaks, color: .black.opacity(0.55), fraction: Double(clip.length.rawValue) / max(1, assetTicks), loop: a.loop)
                    .padding(.top, 16).padding(.bottom, 3)
            }
            Text(model.clipName(clip)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 5).padding(.top, 2).lineLimit(1)
        }
        .frame(width: w, height: laneHeight - 6)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? .white : .black.opacity(0.4), lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .trailing) {
            Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { resize = $0.translation.width }
                    .onEnded { g in
                        let end = model.snap(xTick(tickX(clip.start + clip.length, model) + g.translation.width, model))
                        resize = 0
                        if end > clip.start { model.apply(.setClipRange(clip: clip.id, start: clip.start, length: end - clip.start)) }
                    })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .offset(x: x + drag.width, y: 3 + drag.height)
        .zIndex(drag == .zero ? 0 : 10)
        .onTapGesture { model.selectedClip = clip.id; model.selectedTrack = track.id }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { drag = $0.translation }
            .onEnded { g in
                drag = .zero
                let start = model.snap(xTick(x + g.translation.width, model))
                let shift = Int((g.translation.height / laneHeight).rounded())
                let target = model.project.tracks[min(max(0, trackIndex + shift), trackCount - 1)]
                model.apply(.moveClip(clip: clip.id, toTrack: target.id, start: start))
            })
        .contextMenu { Button("Delete", role: .destructive) { model.apply(.removeClip(clip: clip.id)) } }
    }
}

private struct Playhead: View {
    @Environment(AppModel.self) private var model
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.transportPlaying)) { _ in
            Rectangle().fill(.white).frame(width: 1.5, height: height)
                .offset(x: tickX(model.currentTick, model))
        }
        .allowsHitTesting(false)
    }
}

private struct LoopBrace: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    @State private var dragStart: CGFloat = 0
    @State private var dragEnd: CGFloat = 0

    var body: some View {
        if let loop = model.project.loop, loop.enabled {
            let x0 = tickX(loop.start, model) + dragStart
            let x1 = tickX(loop.end, model) + dragEnd
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.accent.opacity(0.07)).frame(width: max(1, x1 - x0)).offset(x: x0)
                Rectangle().fill(Theme.accent).frame(width: max(1, x1 - x0), height: 5).offset(x: x0, y: rulerHeight - 5)
                handle(x: x0).gesture(DragGesture().onChanged { dragStart = $0.translation.width }.onEnded { g in
                    dragStart = 0
                    model.setLoop(start: model.snap(xTick(tickX(loop.start, model) + g.translation.width, model)), end: loop.end)
                })
                handle(x: x1 - 6).gesture(DragGesture().onChanged { dragEnd = $0.translation.width }.onEnded { g in
                    dragEnd = 0
                    model.setLoop(start: loop.start, end: model.snap(xTick(tickX(loop.end, model) + g.translation.width, model)))
                })
            }
        }
    }

    private func handle(x: CGFloat) -> some View {
        Rectangle().fill(Theme.accent).frame(width: 6, height: 14).offset(x: x, y: rulerHeight - 14).contentShape(Rectangle())
    }
}
