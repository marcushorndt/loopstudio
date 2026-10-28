import SwiftUI

/// The colours of one theme. Every view reads colours from `Theme`, so a new theme is a new palette.
struct ThemePalette: Sendable {
    var name: String
    var background: Color      // window and empty areas
    var panel: Color           // cards: sidebar, inspector, mixer
    var panelRaised: Color     // hover, selected, controls
    var line: Color            // hairline borders
    var text: Color
    var dim: Color
    var accent: Color
    var play: Color
    var onTint: Color          // text on a coloured clip
    var clipFill: Double       // how strongly a clip shows its track colour, 0...1
    var trackColors: [Color]

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// shadcn "zinc", dark. Quiet surfaces, hairline borders, one accent.
    static let zincDark = ThemePalette(
        name: "Zinc Dark",
        background: hex(0x09090B), panel: hex(0x111113), panelRaised: hex(0x1C1C20), line: hex(0x27272A),
        text: hex(0xFAFAFA), dim: hex(0x8E8E99), accent: hex(0x818CF8), play: hex(0x4ADE80),
        onTint: hex(0xFAFAFA), clipFill: 0.26,
        trackColors: [hex(0xFB7185), hex(0xFB923C), hex(0xFACC15), hex(0x4ADE80), hex(0x2DD4BF), hex(0x60A5FA), hex(0xA78BFA), hex(0xF472B6)])

    /// shadcn "zinc", light.
    static let zincLight = ThemePalette(
        name: "Zinc Light",
        background: hex(0xFAFAFA), panel: hex(0xFFFFFF), panelRaised: hex(0xF4F4F5), line: hex(0xE4E4E7),
        text: hex(0x18181B), dim: hex(0x71717A), accent: hex(0x4F46E5), play: hex(0x16A34A),
        onTint: hex(0x18181B), clipFill: 0.30,
        trackColors: [hex(0xE11D48), hex(0xEA580C), hex(0xCA8A04), hex(0x16A34A), hex(0x0D9488), hex(0x2563EB), hex(0x7C3AED), hex(0xDB2777)])

    static let all: [ThemePalette] = [zincDark, zincLight]

    static func named(_ name: String?) -> ThemePalette { all.first { $0.name == name } ?? zincDark }
}

enum Theme {
    /// The active palette. The app sets it once at start and when the user picks another theme.
    nonisolated(unsafe) static var palette = ThemePalette.zincDark

    static var background: Color { palette.background }
    static var panel: Color { palette.panel }
    static var panelRaised: Color { palette.panelRaised }
    static var line: Color { palette.line }
    static var text: Color { palette.text }
    static var dim: Color { palette.dim }
    static var accent: Color { palette.accent }
    static var play: Color { palette.play }
    static var onTint: Color { palette.onTint }
    static var trackColors: [Color] { palette.trackColors }

    static let radius: CGFloat = 6

    static func track(_ index: Int) -> Color { trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count] }

    /// A clip body: the track colour, softened, on the panel.
    static func clipBody(_ index: Int, active: Bool = false) -> Color {
        track(index).opacity(active ? min(1, palette.clipFill + 0.34) : palette.clipFill)
    }
}
