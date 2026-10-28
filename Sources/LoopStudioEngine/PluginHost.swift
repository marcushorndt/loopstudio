import Foundation
import LoopStudioCore

/// Keeps one loaded Audio Unit per device of the project.
/// Loading is asynchronous (some plugins take seconds), so the mix plays without a plugin until it is ready.
@MainActor
public final class PluginHost {
    public private(set) var units: [DeviceID: AudioUnitEffect] = [:]
    public private(set) var failures: [DeviceID: String] = [:]
    private var loading: Set<DeviceID> = []

    public init() {}

    /// Loads plugins the project uses and drops the ones it no longer uses.
    /// Returns true when the set of loaded plugins changed.
    public func sync(project: Project) async -> Bool {
        var wanted: [DeviceSlot] = []
        for track in project.allTracks { wanted.append(contentsOf: track.devices.filter { $0.format == "audiounit" }) }
        let wantedIDs = Set(wanted.map(\.id))

        var changed = false
        for id in units.keys where !wantedIDs.contains(id) { units[id] = nil; changed = true }
        for id in failures.keys where !wantedIDs.contains(id) { failures[id] = nil }

        for device in wanted where units[device.id] == nil && failures[device.id] == nil && !loading.contains(device.id) {
            loading.insert(device.id)
            defer { loading.remove(device.id) }
            do {
                let unit = try await AudioUnitEffect.instantiate(identifier: device.identifier, sampleRate: project.sampleRate)
                if let state = device.state { unit.restore(state: state) }
                units[device.id] = unit
                changed = true
            } catch {
                failures[device.id] = "\(error)"
                changed = true
            }
        }
        return changed
    }

    /// Current plugin states, to write into the project before saving.
    public func states() -> [DeviceID: Data] {
        var result: [DeviceID: Data] = [:]
        for (id, unit) in units { if let data = unit.savedState() { result[id] = data } }
        return result
    }

    public func removeAll() { units = [:]; failures = [:] }
}
