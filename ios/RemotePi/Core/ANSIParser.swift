import Foundation
import UIKit
import SwiftUI

/**
 * Minimal SOTA-grade ANSI/VT100 renderer for pi message text.
 *
 * pi writes terminal escape sequences (24-bit truecolor, SGR) into thinking
 * and tool output. Rendering them makes the app show exactly what the
 * terminal shows. Supported SGR:
 *   - 38;2;r;g;b / 48;2;r;g;b      truecolor fg/bg
 *   - 38;5;n  / 48;5;n              256-color cube + grayscale
 *   - 30-37 / 40-47 / 90-97 / 100-107  standard + bright
 *   - 1 bold, 3 italic, 2 faint, 4 underline, 7 reverse
 *   - 0 reset, 39/49 default fg/bg
 * Everything else degrades gracefully (sequence dropped).
 */
enum ANSIParser {
    static func attributed(_ input: String,
                           baseFont: UIFont,
                           baseColor: UIColor = .label,
                           backgroundColor: UIColor = .clear) -> NSAttributedString {
        guard input.contains("\u{1B}[") else {
            return NSAttributedString(string: input, attributes: [.font: baseFont, .foregroundColor: baseColor])
        }

        let out = NSMutableAttributedString()
        var fg = baseColor
        var bg = backgroundColor
        var bold = false
        var italic = false
        var faint = false
        var underline = false
        var reverse = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            let effectiveFg = faint ? fg.withAlphaComponent(0.65) : fg
            var attrs: [NSAttributedString.Key: Any] = [
                .font: styledFont(baseFont, bold: bold, italic: italic),
                .foregroundColor: reverse ? bg : effectiveFg,
            ]
            if bg != .clear { attrs[.backgroundColor] = reverse ? effectiveFg : bg }
            if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: buffer, attributes: attrs))
            buffer = ""
        }

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                // Find terminating letter (m for SGR).
                var j = i + 2
                while j < chars.count, !(chars[j].isLetter || chars[j] == "m") { j += 1 }
                guard j < chars.count, chars[j] == "m" else {
                    i = j < chars.count ? j + 1 : chars.count
                    continue
                }
                let params = String(chars[i + 2..<j]).split(separator: ";").compactMap { Int($0) }
                apply(params, &fg, &bg, &bold, &italic, &faint, &underline, &reverse)
                i = j + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    private static func apply(_ params: [Int],
                              _ fg: inout UIColor, _ bg: inout UIColor,
                              _ bold: inout Bool, _ italic: inout Bool,
                              _ faint: inout Bool, _ underline: inout Bool,
                              _ reverse: inout Bool) {
        guard !params.isEmpty else { // bare ESC[m = reset
            reset(&fg, &bg, &bold, &italic, &faint, &underline, &reverse)
            return
        }
        var k = 0
        while k < params.count {
            let p = params[k]
            switch p {
            case 0: reset(&fg, &bg, &bold, &italic, &faint, &underline, &reverse)
            case 1: bold = true
            case 2: faint = true
            case 3: italic = true
            case 4: underline = true
            case 7: reverse = true
            case 22: bold = false; faint = false
            case 23: italic = false
            case 24: underline = false
            case 27: reverse = false
            case 30...37: fg = basePalette[p - 30]
            case 38, 48:
                // Extended color: 38;5;n or 38;2;r;g;b
                let isFg = p == 38
                if k + 1 < params.count, params[k + 1] == 5, k + 2 < params.count {
                    if isFg { fg = palette256(params[k + 2]) } else { bg = palette256(params[k + 2]) }
                    k += 3
                    continue
                }
                if k + 1 < params.count, params[k + 1] == 2, k + 4 < params.count {
                    let color = UIColor(red: CGFloat(params[k + 2]) / 255, green: CGFloat(params[k + 3]) / 255, blue: CGFloat(params[k + 4]) / 255, alpha: 1)
                    if isFg { fg = color } else { bg = color }
                    k += 5
                    continue
                }
            case 39: fg = .label
            case 49: bg = .clear
            case 40...47: bg = basePalette[p - 40]
            case 90...97: fg = brightPalette[p - 90]
            case 100...107: bg = brightPalette[p - 100]
            default: break
            }
            k += 1
        }
    }

    private static func reset(_ fg: inout UIColor, _ bg: inout UIColor,
                              _ bold: inout Bool, _ italic: inout Bool,
                              _ faint: inout Bool, _ underline: inout Bool,
                              _ reverse: inout Bool) {
        fg = .label; bg = .clear; bold = false; italic = false
        faint = false; underline = false; reverse = false
    }

    private static func styledFont(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let desc = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: desc, size: base.pointSize)
        }
        return base
    }

    private static let basePalette: [UIColor] = [
        .black, .systemRed, .systemGreen, .systemYellow, .systemBlue,
        .magenta, .cyan, .systemGray,
    ]
    private static let brightPalette: [UIColor] = [
        .systemGray2, .systemRed, .systemGreen, .systemYellow, .systemBlue,
        .systemPink, .cyan, .white,
    ]

    /// xterm 256-color cube (16 colors + 6x6x6 cube + 24 grays).
    private static func palette256(_ n: Int) -> UIColor {
        if n < 16 { return n < 8 ? basePalette[n] : brightPalette[n - 8] }
        if n < 232 {
            let v = n - 16
            let r = cube(v / 36), g = cube((v / 6) % 6), b = cube(v % 6)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        let g = CGFloat(8 + (n - 232) * 10) / 255
        return UIColor(red: g, green: g, blue: g, alpha: 1)
    }

    private static func cube(_ v: Int) -> CGFloat {
        let vals: [CGFloat] = [0, 95, 135, 175, 215, 255]
        return vals[v] / 255
    }
}

/// Renders ANSI-colored text with terminal styling (dark, monospace).
struct TerminalText: View {
    let text: String
    var color: Color = Color(hex: 0x8FE3A0)
    var fontSize: CGFloat = 12
    var maxLines: Int? = nil

    var body: some View {
        let attributed = ANSIParser.attributed(
            text,
            baseFont: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            baseColor: UIColor(color)
        )
        Text(AttributedString(attributed))
            .ifLet(maxLines) { view, lines in view.lineLimit(lines) }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
