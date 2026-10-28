import Foundation
import LoopStudioCore

/// Builds the plan for an export: the arrangement, the saved Session launches, and hosted plugins in
/// their own offline instances (never the ones the audio thread runs).
public enum OfflineRender {
    /// Unchecked: the plan is read only once built, and the host is main-actor bound.
    public struct Prepared: @unchecked Sendable {
        public var plan: RenderPlan
        /// Plugin load failures and simulator warnings, on top of `plan.warnings`.
        public var warnings: [String]
        /// First frame after the arrangement and the Session performance.
        public var endFrame: Int64
        /// Keeps the plugin instances alive for as long as the plan renders.
        public let host: PluginHost
    }

    @MainActor
    public static func prepare(_ project: Project, bank: AudioBank) async -> Prepared {
        let host = PluginHost()
        _ = await host.sync(project: project)
        var warnings = host.failures.sorted { $0.key.description < $1.key.description }
            .map { "plugin \($0.key) did not load: \($0.value)" }

        var session: SessionSimulation?
        var ends: [TrackID: Int64] = [:]
        var sessionEnd: Int64 = 0
        if !project.launches.isEmpty {
            // The last launch plays one full pass of its clip; a stop launch ends sooner.
            var horizon = Tick(0)
            for launch in project.launches {
                let length = launch.slot.flatMap { s in project.track(launch.track)?.slots.indices.contains(s) == true ? project.track(launch.track)?.slots[s]?.clip.length : nil } ?? Tick(0)
                horizon = max(horizon, launch.tick + length)
            }
            let simulated = SessionSimulator.run(project, horizon: horizon)
            warnings += simulated.warnings
            for track in Set(project.launches.map(\.track)) {
                let starts = simulated.events.filter { $0.track == track }.map(\.startTick)
                let stops = project.launches.filter { $0.track == track && $0.slot == nil }.map(\.tick)
                if let first = (starts + stops).min() {
                    ends[track] = project.tempoMap.frame(at: first, sampleRate: project.sampleRate).rawValue
                }
            }
            session = simulated
            if let last = simulated.events.map(\.endTick).max() {
                sessionEnd = project.tempoMap.frame(at: last, sampleRate: project.sampleRate).rawValue
            }
        }
        let plan = RenderPlan.compile(project, bank: bank, session: session, units: host.units, arrangementEnds: ends)
        return Prepared(plan: plan, warnings: warnings, endFrame: max(plan.endFrame, sessionEnd), host: host)
    }
}
