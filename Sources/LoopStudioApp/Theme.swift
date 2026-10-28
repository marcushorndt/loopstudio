import SwiftUI

enum Theme {
    static let background = Color(white: 0.13)
    static let panel = Color(white: 0.17)
    static let panelRaised = Color(white: 0.22)
    static let line = Color(white: 0.08)
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.55)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.1)
    static let play = Color(red: 0.35, green: 0.85, blue: 0.4)

    static let trackColors: [Color] = [
        Color(red: 0.95, green: 0.45, blue: 0.40), Color(red: 0.98, green: 0.65, blue: 0.30),
        Color(red: 0.95, green: 0.82, blue: 0.35), Color(red: 0.45, green: 0.80, blue: 0.45),
        Color(red: 0.30, green: 0.78, blue: 0.75), Color(red: 0.40, green: 0.60, blue: 0.95),
        Color(red: 0.62, green: 0.50, blue: 0.95), Color(red: 0.88, green: 0.50, blue: 0.85),
    ]
    static func track(_ index: Int) -> Color { trackColors[((index % trackColors.count) + trackColors.count) % trackColors.count] }
}
