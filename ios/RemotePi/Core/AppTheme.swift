import SwiftUI
import UIKit

/// Semantic theme palette — views read `@Environment(\.theme)` instead of
/// hardcoding system colors, so the app can switch between pleasant palettes.
struct AppTheme {
    let name: String
    /// Root / list background (soft dark grey, not pure black).
    let background: Color
    /// Cards, bubbles, inputs.
    let secondaryBackground: Color
    /// Tool/note blocks.
    let surface: Color
    let text: Color
    let secondaryText: Color
    let accent: Color
    let border: Color
    /// Terminal-style tool output.
    let terminalBackground: Color
    let terminalText: Color
    let userBubble: Color
    let noteBackground: Color
    let errorBackground: Color

    var scheme: ColorScheme { name == "light" ? .light : .dark }

    static let darkGrey = AppTheme(
        name: "darkGrey",
        background: Color(hex: 0x1E1F23),
        secondaryBackground: Color(hex: 0x28292E),
        surface: Color(hex: 0x232428),
        text: Color(hex: 0xE6E7EB),
        secondaryText: Color(hex: 0x9CA0AA),
        accent: Color(hex: 0x5B8DEF),
        border: Color(hex: 0x34353B),
        terminalBackground: Color(hex: 0x17181B),
        terminalText: Color(hex: 0x8FE3A0),
        userBubble: Color(hex: 0x4A7DD6),
        noteBackground: Color(hex: 0x2A2B30),
        errorBackground: Color(hex: 0x3A2226)
    )

    static let black = AppTheme(
        name: "black",
        background: Color(hex: 0x000000),
        secondaryBackground: Color(hex: 0x161616),
        surface: Color(hex: 0x1D1D1D),
        text: Color(hex: 0xEAEAEA),
        secondaryText: Color(hex: 0x8A8A8A),
        accent: Color(hex: 0x4A8DFF),
        border: Color(hex: 0x2A2A2A),
        terminalBackground: Color(hex: 0x000000),
        terminalText: Color(hex: 0x7FD88F),
        userBubble: Color(hex: 0x3B82F6),
        noteBackground: Color(hex: 0x1A1A1A),
        errorBackground: Color(hex: 0x331111)
    )

    static let light = AppTheme(
        name: "light",
        background: Color(hex: 0xF4F5F7),
        secondaryBackground: Color(hex: 0xFFFFFF),
        surface: Color(hex: 0xECEDF0),
        text: Color(hex: 0x1C1D21),
        secondaryText: Color(hex: 0x6B6E76),
        accent: Color(hex: 0x2F6FDB),
        border: Color(hex: 0xD9DBE0),
        terminalBackground: Color(hex: 0x1E1F23),
        terminalText: Color(hex: 0x8FE3A0),
        userBubble: Color(hex: 0x2F6FDB),
        noteBackground: Color(hex: 0xE8E9EC),
        errorBackground: Color(hex: 0xF6D7D9)
    )

    static func named(_ name: String) -> AppTheme {
        switch name {
        case "black": return .black
        case "light": return .light
        default: return .darkGrey
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.darkGrey
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
