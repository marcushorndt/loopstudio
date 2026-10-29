import Foundation
import LoopStudioCore

/// Keeps one loaded Audio Unit per device of the project.
/// Loading is asynchronous (some plugins take seconds), so the mix plays without a plugin until it is ready.
@MainActor
public final class PluginHost {
    public private(set) var units: [DeviceID: AudioUnitEffect] = [:]
    public private(set) var failures: [DeviceID: String] = [:]
    private var loading: Set<DeviceID> = []
    /// Goes up on `removeAll()`. A load that started in an older generation belongs to another project.
    private var generation = 0
    /// The plugin each device wants, from the latest `sync`. A load that finishes is kept only if it still matches.
    private var wanted: [DeviceID: String] = [:]

    public init() {}

    /// Plugins load in a separate process (crash isolation). Changes apply to plugins loaded from then on.
    public var outOfProcess = true

    /// True while a plugin is loading.
    public var isLoading: Bool { !loading.isEmpty }

    /// Loads plugins the project uses and drops the ones it no longer uses.
    /// Returns true when the set of loaded plugins changed.
    public func sync(project: Project) async -> Bool {
        var wanted: [DeviceSlot] = []
        for track in project.allTracks { wanted.append(contentsOf: track.devices.filter { $0.format == "audiounit" }) }
        let wantedIDs = Set(wanted.map(\.id))
        self.wanted = Dictionary(wanted.map { ($0.id, $0.identifier) }, uniquingKeysWith: { a, _ in a })
        let started = generation

        var changed = false
        for id in units.keys where !wantedIDs.contains(id) { units[id] = nil; changed = true }
        for id in failures.keys where !wantedIDs.contains(id) { failures[id] = nil }

        for device in wanted where units[device.id] == nil && failures[device.id] == nil && !loading.contains(device.id) {
            loading.insert(device.id)
            let isolated = outOfProcess
            let result = await Result { try await AudioUnitEffect.instantiate(identifier: device.identifier, sampleRate: project.sampleRate, outOfProcess: isolated) }
            // Another project was opened, or the device was removed or changed, while the plugin loaded.
            guard generation == started else { return changed }
            loading.remove(device.id)
            guard self.wanted[device.id] == device.identifier, units[device.id] == nil else { continue }
            switch result {
            case .success(let unit):
                if let state = device.state { unit.restore(state: state) }
                units[device.id] = unit
            case .failure(let error):
                failures[device.id] = "\(error)"
            }
            changed = true
        }
        return changed
    }

    /// Current plugin states, to write into the project before saving.
    public func states() -> [DeviceID: Data] {
        var result: [DeviceID: Data] = [:]
        for (id, unit) in units { if let data = unit.savedState() { result[id] = data } }
        return result
    }

    /// Drops every plugin and every load still running (for another project).
    public func removeAll() { units = [:]; failures = [:]; loading = []; wanted = [:]; generation += 1 }
}
