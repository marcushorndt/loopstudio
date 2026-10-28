import LoopStudioCore
import LoopStudioEngine
import SwiftUI

/// Sound card, output channels, buffer size and MIDI devices. Opens with ⌘,.
struct AudioSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioDeviceInfo] = []
    @State private var midi: [MIDIEndpointInfo] = []

    private var outputs: [AudioDeviceInfo] { devices.filter { !$0.outputs.isEmpty } }
    private var current: AudioDeviceInfo? {
        let uid = model.outputUID ?? AudioDeviceCatalog.defaultOutputUID()
        return outputs.first { $0.uid == uid }
    }

    var body: some View {
        Form {
            Section("Audio output") {
                Picker("Device", selection: Binding(get: { model.outputUID ?? "" }, set: { model.outputUID = $0.isEmpty ? nil : $0; model.outputLeft = 0; model.applyAudioSettings() })) {
                    Text("System default").tag("")
                    ForEach(outputs, id: \.uid) { Text("\($0.name) (\($0.outputs.count) out)").tag($0.uid) }
                }
                if let device = current, device.outputs.count > 2 {
                    Picker("Master out", selection: Binding(get: { model.outputLeft }, set: { model.outputLeft = $0; model.applyAudioSettings() })) {
                        ForEach(Array(stride(from: 0, to: device.outputs.count - 1, by: 2)), id: \.self) { i in
                            Text("\(device.outputs[i].name) + \(device.outputs[i + 1].name)").tag(i)
                        }
                    }
                }
                if let device = current {
                    Picker("Buffer size", selection: Binding(get: { model.bufferFrames }, set: { model.bufferFrames = $0; model.applyAudioSettings() })) {
                        Text("Device default").tag(0)
                        ForEach([32, 64, 128, 256, 512, 1024, 2048].filter { $0 >= device.bufferMin && $0 <= device.bufferMax }, id: \.self) {
                            Text("\($0) frames (\(String(format: "%.1f", Double($0) / model.sampleRate * 1000)) ms)").tag($0)
                        }
                    }
                    Text("Latency of the device: \(device.outputLatencyFrames) frames. Sample rates: \(device.sampleRates.map { "\(Int($0))" }.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Section("MIDI inputs") {
                if midi.isEmpty { Text("No MIDI device found").foregroundStyle(Theme.dim) }
                ForEach(midi, id: \.uniqueID) { Text("\($0.name)\($0.isOffline ? " (offline)" : "")") }
                Text("Every MIDI input plays the selected MIDI track.").font(.caption).foregroundStyle(Theme.dim)
            }
            Section {
                Button("Rescan Devices") { rescan() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .onAppear { rescan() }
    }

    private func rescan() {
        devices = AudioDeviceCatalog.devices()
        midi = MIDIEndpointCatalog.sources()
    }
}
