import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import LoopStudioEngine
import SwiftUI

/// Opens a plugin's own window. A plugin without a custom view gets a plain list of its parameters.
///
/// A plugin view tells its size late, and some change it after they are on screen (Apple's multiband
/// compressor lays its bands out after the first draw). So the window takes the size the view asks for,
/// follows later changes, and stays inside the screen. A closed window is kept and shown again on the next
/// open: a plugin hands out the same view every time, and a view moved between windows keeps a stale frame.
@MainActor
enum PluginWindow {
    private final class Entry {
        weak var plugin: AudioUnitEffect?
        let window: NSWindow
        let controller: NSViewController
        var observation: NSKeyValueObservation?
        var sized = false
        init(plugin: AudioUnitEffect, window: NSWindow, controller: NSViewController) {
            self.plugin = plugin; self.window = window; self.controller = controller
        }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func show(_ plugin: AudioUnitEffect, title: String) {
        let key = ObjectIdentifier(plugin)
        // The same plugin: the same window. Another plugin that got a freed one's address: a new window.
        if let entry = entries[key] {
            if entry.plugin === plugin {
                entry.window.title = title
                entry.window.makeKeyAndOrderFront(nil)
                keepOnScreen(entry.window)
                return
            }
            entry.window.close()
            entries[key] = nil
        }
        plugin.unit.requestViewController { controller in
            Task { @MainActor in
                let content: NSViewController = controller ?? NSHostingController(rootView: GenericParameters(unit: plugin.unit))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = title
                window.isReleasedWhenClosed = false
                window.contentMinSize = NSSize(width: 280, height: 160)
                window.contentViewController = content
                content.view.autoresizingMask = [.width, .height]
                let entry = Entry(plugin: plugin, window: window, controller: content)
                entries[key] = entry
                fit(entry)
                window.center()
                keepOnScreen(window)
                window.makeKeyAndOrderFront(nil)
                // The view may still change its mind after it is on screen.
                entry.observation = content.observe(\.preferredContentSize) { _, _ in
                    Task { @MainActor in if let e = entries[key] { fit(e) } }
                }
                for delay in [0.1, 0.5, 1.5] {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        fit(entry)
                    }
                }
            }
        }
    }

    /// The size the plugin view wants now, when it says one.
    private static func wantedSize(_ controller: NSViewController) -> NSSize? {
        for size in [controller.preferredContentSize, controller.view.fittingSize, controller.view.frame.size]
        where size.width >= 100 && size.height >= 60 && size.width < 4_000 && size.height < 4_000 {
            return size
        }
        return nil
    }

    /// Gives the window the size the view wants, if that changed, and keeps the top edge where it is.
    private static func fit(_ entry: Entry) {
        guard let size = wantedSize(entry.controller) else { return }
        let window = entry.window
        let current = window.contentRect(forFrameRect: window.frame).size
        if entry.sized, abs(current.width - size.width) < 2, abs(current.height - size.height) < 2 { return }
        // The user made it bigger on purpose: keep that.
        if entry.sized, current.width >= size.width, current.height >= size.height { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        entry.sized = true
        keepOnScreen(window)
    }

    /// Moves (and if needed shrinks) the window so that all of it is on the screen.
    private static func keepOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if frame.height > visible.height { frame.size.height = visible.height }
        if frame.width > visible.width { frame.size.width = visible.width }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}

private struct GenericParameters: View {
    let unit: AUAudioUnit

    var body: some View {
        let parameters = unit.parameterTree?.allParameters ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if parameters.isEmpty { Text("This plugin has no parameters.").foregroundStyle(.secondary) }
                ForEach(parameters, id: \.address) { ParameterRow(parameter: $0) }
            }
            .padding(14)
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 120, idealHeight: min(600, CGFloat(60 + parameters.count * 34)))
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: Double

    init(parameter: AUParameter) {
        self.parameter = parameter
        _value = State(initialValue: Double(parameter.value))
    }

    var body: some View {
        HStack {
            Text(parameter.displayName).frame(width: 150, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { value }, set: { value = $0; parameter.setValue(AUValue($0), originator: nil) }),
                   in: Double(parameter.minValue)...Double(max(parameter.maxValue, parameter.minValue + 0.0001)))
            Text(String(format: "%.2f", value)).font(.system(size: 11, design: .monospaced)).frame(width: 60, alignment: .trailing)
        }
    }
}
