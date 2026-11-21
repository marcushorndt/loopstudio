import Foundation
import LoopStudioCore
import LoopStudioProject

/// The side files beside the audio in the package (`audio/<hash>.warp`, `audio/<hash>.notes`), after Live's
/// `.asd` files, and the clean-up of note renders that nothing plays any more.
extension AppModel {
    /// The warp of the clip warped last, for the next clip of the same file.
    struct WarpDefault: Codable, Equatable {
        var mode: WarpMode
        var markers: [WarpMarker]
        var settings: WarpSettings?
    }

    /// The file a clip's warp belongs to: the original, also for a clip that plays a note render.
    private func warpOwner(_ a: AudioClip) -> Asset? { project.asset(a.noteEdit?.source ?? a.asset) }

    func warpDefaultURL(_ asset: Asset) -> URL { AssetStore.sidecarURL(sha256: asset.sha256, ext: "warp", in: packageURL) }

    func warpDefault(for asset: Asset) -> WarpDefault? {
        guard let data = try? Data(contentsOf: warpDefaultURL(asset)) else { return nil }
        return try? JSONDecoder().decode(WarpDefault.self, from: data)
    }

    /// After an edit: a clip whose warp changed writes it beside its file.
    func rememberWarp(after command: Command) {
        var clips: [ClipID] = []
        func collect(_ c: Command) {
            switch c {
            case .setClipWarp(let id, _, _), .setClipWarpSettings(let id, _): clips.append(id)
            case .batch(let commands): commands.forEach(collect)
            default: break
            }
        }
        collect(command)
        for id in clips {
            guard case .audio(let a)? = project.findClip(id)?.clip, let asset = warpOwner(a) else { continue }
            let value = WarpDefault(mode: a.warpMode, markers: a.warpMarkers, settings: a.warpSettings)
            guard value != warpDefault(for: asset), let data = try? JSONEncoder().encode(value) else { continue }
            let url = warpDefaultURL(asset)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// A new clip of a file: with the warp the file's last warped clip had, as Live does from its `.asd`.
    func newAudioClip(asset: Asset, start: Tick, length: Tick) -> AudioClip {
        var clip = project.makeAudioClip(asset: asset.id, start: start, length: length)
        if let d = warpDefault(for: asset) {
            clip.warpMode = d.mode
            clip.warpMarkers = d.markers
            clip.warpSettings = d.settings
        }
        return clip
    }
}
