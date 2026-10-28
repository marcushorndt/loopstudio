import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import LoopStudioEngine
import SwiftUI

/// Opens a plugin's own window. A plugin without a custom view gets a plain list of its parameters.
@MainActor
enum PluginWindow {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]

    static func show(_ plugin: AudioUnitEffect, title: String) {
        let key = ObjectIdentifier(plugin)
        if let existing = windows[key] { existing.makeKeyAndOrderFront(nil); return }
        plugin.unit.requestViewController { controller in
            Task { @MainActor in
                let content: NSViewController = controller ?? NSHostingController(rootView: GenericParameters(unit: plugin.unit))
                let window = NSWindow(contentViewController: content)
                window.title = title
                window.styleMask.insert([.closable, .miniaturizable])
                window.isReleasedWhenClosed = false
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    Task { @MainActor in windows[key] = nil }
                }
                windows[key] = window
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }
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
        .frame(width: 420, height: min(600, CGFloat(60 + parameters.count * 34)))
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
