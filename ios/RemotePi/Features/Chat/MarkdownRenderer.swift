import UIKit

/// Markdown → NSAttributedString for the UIKit transcript.
///
/// Thread-safe and pure (Foundation's `AttributedString(markdown:)` + UIFont
/// /UIColor values only), so it runs on the transcript's background render
/// queue — never on the main thread.
///
/// Supported: inline bold/italic/code/strikethrough/links (Foundation inline
/// parser, iOS 15), ATX headers (`#`…`######`), `-`/`*`/`+` bullets, and
/// fenced code blocks (monospace + code background).
enum MarkdownRenderer {
    /// Links are stored under a private key: UIKit string drawing would
    /// otherwise restyle `.link` runs. The context menu reads this key.
    static let linkKey = NSAttributedString.Key("RemotePiTranscriptLink")

    struct Palette {
        let text: UIColor
        let accent: UIColor
        let codeBackground: UIColor
    }

    static func plain(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    static func render(_ text: String, font: UIFont, palette: Palette) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mono = UIFont.monospacedSystemFont(ofSize: max(10, font.pointSize * 0.88), weight: .regular)
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false

        func appendSegment(_ segment: NSAttributedString) {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: palette.text]))
            }
            result.append(segment)
        }
        func flushProse() {
            guard !prose.isEmpty else { return }
            appendSegment(renderProse(prose.joined(separator: "\n"), font: font, mono: mono, palette: palette))
            prose.removeAll()
        }
        func flushCode() {
            guard !code.isEmpty else { return }
            let body = code.joined(separator: "\n")
            appendSegment(NSAttributedString(string: body, attributes: [
                .font: mono,
                .foregroundColor: palette.text,
                .backgroundColor: palette.codeBackground,
            ]))
            code.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        flushProse()
        flushCode()
        return result
    }

    // MARK: - Prose (headers, bullets, inline)

    private static func renderProse(_ source: String, font: UIFont, mono: UIFont,
                                    palette: Palette) -> NSAttributedString {
        var headerLevels: [Int: Int] = [:]
        var lines: [String] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            if let level = headerLevel(of: line) {
                headerLevels[index] = level
                line = String(line.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
            } else if let bulleted = bulletLine(line) {
                line = bulleted
            }
            lines.append(line)
        }
        let out = inline(escapeFalseTildes(lines.joined(separator: "\n")), font: font, mono: mono, palette: palette)
        guard !headerLevels.isEmpty else { return out }

        // The inline parser preserves newlines, so line N of the output is
        // line N of the input.
        let ns = out.string as NSString
        var lineIndex = 0
        var location = 0
        while location <= ns.length {
            let searchRange = NSRange(location: location, length: ns.length - location)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            let end = newline.location == NSNotFound ? ns.length : newline.location
            if let level = headerLevels[lineIndex], end > location {
                let scale: [CGFloat] = [1.3, 1.2, 1.1, 1.05, 1.0, 1.0]
                let size = font.pointSize * scale[min(max(level, 1), 6) - 1]
                out.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: .bold),
                                 range: NSRange(location: location, length: end - location))
            }
            if newline.location == NSNotFound { break }
            location = end + 1
            lineIndex += 1
        }
        return out
    }

    private static func headerLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1; continue }
            return (ch == " " && (1...6).contains(count)) ? count : nil
        }
        return nil
    }

    private static func bulletLine(_ line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard rest.count >= 2, let first = rest.first, "-*+".contains(first),
              rest.dropFirst().first == " " else { return nil }
        return String(indent) + "• " + String(rest.dropFirst(2))
    }

    private static func inline(_ source: String, font: UIFont, mono: UIFont,
                               palette: Palette) -> NSMutableAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.text]
        guard let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSMutableAttributedString(string: source, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            guard !piece.isEmpty else { continue }
            var attrs = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attrs[.font] = mono
                    attrs[.backgroundColor] = palette.codeBackground
                } else {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        attrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
                    }
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let url = run.link {
                attrs[linkKey] = url
                attrs[.foregroundColor] = palette.accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    /// Neutralize tildes outside code spans so the parser never renders
    /// strikethrough from paths (`~/x`) or approximations (`~5s`).
    static func escapeFalseTildes(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var out = ""
        out.reserveCapacity(text.count + 16)
        var inBackticks = false
        for ch in text {
            if ch == "`" {
                inBackticks.toggle()
                out.append(ch)
            } else if ch == "~" && !inBackticks {
                out.append("\\~")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// URLs in a rendered string (markdown links) plus bare URLs in the text.
    static func links(in rendered: NSAttributedString, text: String) -> [URL] {
        var urls: [URL] = []
        rendered.enumerateAttribute(linkKey, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL, !urls.contains(url) { urls.append(url) }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                if let url = match.url, !urls.contains(url) { urls.append(url) }
            }
        }
        return urls
    }
}
