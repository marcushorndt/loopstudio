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
            Section("Direct outputs") {
                let ports = model.assignablePorts
                if let device = current, device.outputs.count > 2 {
                    ForEach(ports, id: \.id) { port in
                        Picker(port.name, selection: Binding(get: { model.portLeft(port) }, set: { model.setPortLeft(port, $0) })) {
                            ForEach(Array(stride(from: 0, to: device.outputs.count - 1, by: 2)), id: \.self) { i in
                                Text("\(device.outputs[i].name) + \(device.outputs[i + 1].name)").tag(i)
                            }
                        }
                    }
                    Text("A track set to \"Ext. Out\" plays on these channels, past the master.")
                        .font(.caption).foregroundStyle(Theme.dim)
                } else {
                    Text("This sound card has two outputs. A track set to \"Ext. Out\" plays on the master pair, past the master fader.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Section("Audio input (recording)") {
                Text("The channels below are the default. Each audio track can choose its own under Audio From.")
                    .font(.caption).foregroundStyle(Theme.dim)
                let inputs = devices.filter { !$0.inputs.isEmpty }
                Picker("Device", selection: Binding(get: { model.inputUID ?? "" }, set: { model.inputUID = $0.isEmpty ? nil : $0; model.inputLeft = 0 })) {
                    Text("System default").tag("")
                    ForEach(inputs, id: \.uid) { Text("\($0.name) (\($0.inputs.count) in)").tag($0.uid) }
                }
                let device = inputs.first { $0.uid == (model.inputUID ?? AudioDeviceCatalog.defaultInputUID()) }
                if let device {
                    Picker("Channels", selection: Binding(get: { "\(model.inputStereo ? 1 : 0)-\(model.inputLeft)" }, set: { v in
                        let p = v.split(separator: "-"); model.inputStereo = p[0] == "1"; model.inputLeft = Int(p[1]) ?? 0
                    })) {
                        ForEach(device.inputs.indices, id: \.self) { Text("Mono: \(device.inputs[$0].name)").tag("0-\($0)") }
                        ForEach(Array(stride(from: 0, to: max(0, device.inputs.count - 1), by: 2)), id: \.self) {
                            Text("Stereo: \(device.inputs[$0].name) + \(device.inputs[$0 + 1].name)").tag("1-\($0)")
                        }
                    }
                    Text("Input latency: \(device.inputLatencyFrames) frames. A take is moved earlier by the round trip, so it lines up.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Section("MIDI inputs") {
                if midi.isEmpty { Text("No MIDI device found").foregroundStyle(Theme.dim) }
                ForEach(midi, id: \.uniqueID) { Text("\($0.name)\($0.isOffline ? " (offline)" : "")") }
                Text("Each MIDI track chooses its device and channel in the mixer (MIDI From). Armed tracks get the notes.").font(.caption).foregroundStyle(Theme.dim)
            }
            Section("MIDI clock out") {
                let outs = MIDIEndpointCatalog.destinations()
                Picker("Send clock to", selection: Binding(get: { model.midiClockUID ?? Int32.min }, set: { model.midiClockUID = $0 == Int32.min ? nil : $0 })) {
                    Text("Off").tag(Int32.min)
                    ForEach(outs, id: \.uniqueID) { Text($0.name).tag($0.uniqueID) }
                    if let uid = model.midiClockUID, !outs.contains(where: { $0.uniqueID == uid }) { Text("Device offline").tag(uid) }
                }
                Text("Hardware on this port follows the tempo and the transport: Start, Stop and the song position go with the clock.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            Section("Plugins") {
                Toggle("Run plugins in a separate process", isOn: Binding(
                    get: { model.host.outOfProcess },
                    set: { model.host.outOfProcess = $0; UserDefaults.standard.set($0, forKey: "pluginsOutOfProcess") }))
                Text("A plugin that crashes then cannot take LoopStudio down. It costs a little latency and CPU. Applies to plugins loaded from now on; reopen the project for the ones already loaded.")
                    .font(.caption).foregroundStyle(Theme.dim)
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
