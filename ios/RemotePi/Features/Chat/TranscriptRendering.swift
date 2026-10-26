import UIKit
import SwiftUI

// MARK: - Style

/// Resolved UIKit colors/fonts for the transcript. Built on the main thread,
/// then only READ (UIFont/UIColor are immutable and thread-safe), so it can
/// be handed to the background render queue.
struct TranscriptStyle {
    /// Identity of everything that affects rendering (theme, size, category).
    let key: String
    let bodyFont: UIFont
    let headerFont: UIFont
    let footerFont: UIFont
    let text: UIColor
    let secondaryText: UIColor
    let accent: UIColor
    let userBubble: UIColor
    let userText: UIColor
    let background: UIColor
    let secondaryBackground: UIColor
    let border: UIColor
    let errorBackground: UIColor
    let codeBackground: UIColor
    let chipTint: UIColor
    let chipBackground: UIColor
    let offlineBackground: UIColor

    init(theme: AppTheme, textScale: Double, contentSize: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSize)
        // Dynamic Type × the in-app text-size setting.
        let bodySize = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 17 * CGFloat(textScale), compatibleWith: traits)
        key = "\(theme.name)|\(textScale)|\(contentSize.rawValue)"
        bodyFont = UIFont.systemFont(ofSize: bodySize)
        headerFont = UIFont.systemFont(ofSize: UIFontMetrics(forTextStyle: .caption2)
            .scaledValue(for: 11, compatibleWith: traits), weight: .semibold)
        footerFont = UIFont.systemFont(ofSize: UIFontMetrics(forTextStyle: .caption1)
            .scaledValue(for: 12, compatibleWith: traits), weight: .semibold)
        text = UIColor(theme.text)
        secondaryText = UIColor(theme.secondaryText)
        accent = UIColor(theme.accent)
        userBubble = UIColor(theme.userBubble)
        userText = .white
        background = UIColor(theme.background)
        secondaryBackground = UIColor(theme.secondaryBackground)
        border = UIColor(theme.border)
        errorBackground = UIColor(theme.errorBackground)
        codeBackground = UIColor(theme.secondaryBackground)
        chipTint = .systemOrange
        chipBackground = UIColor.systemOrange.withAlphaComponent(0.25)
        offlineBackground = .secondarySystemBackground
    }

    var palette: MarkdownRenderer.Palette {
        MarkdownRenderer.Palette(text: text, accent: accent, codeBackground: codeBackground)
    }
}

// MARK: - Layout

/// Frames for one row, in the cell's contentView coordinates (computed off
/// the main thread with the same string-drawing engine the cell draws with,
/// so heights are exact — no estimated-height corrections, ever).
struct RowLayout: Equatable {
    /// One vertical segment of a tall body (see `TextChunker`).
    struct Chunk: Equatable {
        /// UTF-16 range of the body drawn by this segment.
        var range: NSRange
        /// Frame in contentView coordinates.
        var frame: CGRect
    }

    var width: CGFloat = 0
    var height: CGFloat = 44
    var bubble: CGRect = .zero
    var text: CGRect = .zero
    /// Width the text is wrapped/drawn at (same as when measured).
    var drawWidth: CGFloat = 0
    var header: CGRect = .zero
    var footer: CGRect = .zero
    /// Tall bodies are drawn as stacked segments (empty = one view draws the
    /// whole body). Frames tile `text` exactly.
    var chunks: [Chunk] = []
}

/// Everything a cell needs for one row, cached per row id.
struct RowRender {
    let renderKey: String
    let body: NSAttributedString
    let layout: RowLayout
    let footerTitle: String?
    let isLong: Bool
    /// Pre-sliced bodies for `layout.chunks` (empty when not segmented).
    let segments: [NSAttributedString]
}

enum TranscriptMetrics {
    static let hPad: CGFloat = 12
    static let vPad: CGFloat = 6
    static let userLeadingMin: CGFloat = 60
    static let assistantLeading: CGFloat = 4
    static let assistantTrailingMin: CGFloat = 24
    static let bubbleHPad: CGFloat = 14
    static let bubbleVPad: CGFloat = 10
    static let errorPad: CGFloat = 10
    static let headerHeight: CGFloat = 18
    static let headerGap: CGFloat = 4
    static let headerIcon: CGFloat = 14
    static let headerButton: CGFloat = 22
    static let footerHeight: CGFloat = 22
    static let footerGap: CGFloat = 6
    static let userCorner: CGFloat = 16
    static let errorCorner: CGFloat = 12
    /// Collapse thresholds for long user inputs (logs, dumps, pastes).
    static let collapseChars = 1_200
    static let collapseLines = 20
    static let previewChars = 800
    static let previewLines = 12
    /// Context-menu previews show at most this much of the body.
    static let previewMaxTextHeight: CGFloat = 600
}

enum TranscriptRenderer {
    struct Job {
        let id: String
        let item: TranscriptItem
        let expanded: Bool
        let renderKey: String
    }

    static func renderKey(_ item: TranscriptItem, expanded: Bool, styleKey: String) -> String {
        "\(item.kind.rawValue)|\(item.text.utf8.count)|\(item.text.hashValue)|\(item.streaming ? 1 : 0)|\(expanded ? 1 : 0)|\(item.statusText ?? "")|\(item.cancellable ? 1 : 0)|\(styleKey)"
    }

    static func lineCount(_ text: String) -> Int {
        text.reduce(into: 1) { count, ch in if ch == "\n" || ch == "\r\n" { count += 1 } }
    }

    static func isLongUserText(_ item: TranscriptItem) -> Bool {
        item.kind == .user
            && (item.text.count > TranscriptMetrics.collapseChars
                || lineCount(item.text) > TranscriptMetrics.collapseLines)
    }

    static func collapsedPreview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(TranscriptMetrics.previewLines)
        let head = lines.joined(separator: "\n")
        return String(head.prefix(TranscriptMetrics.previewChars)) + "\n…"
    }

    /// Pure, thread-safe body rendering.
    static func body(for item: TranscriptItem, expanded: Bool, style: TranscriptStyle) -> NSAttributedString {
        switch item.kind {
        case .user:
            let text = (isLongUserText(item) && !expanded) ? collapsedPreview(item.text) : item.text
            return MarkdownRenderer.plain(text, font: style.bodyFont, color: style.userText)
        case .assistant:
            // Plain while streaming: a markdown re-parse per delta is O(n²).
            if item.streaming {
                return MarkdownRenderer.plain(item.text, font: style.bodyFont, color: style.text)
            }
            return MarkdownRenderer.render(item.text, font: style.bodyFont, palette: style.palette)
        case .error:
            return MarkdownRenderer.plain("⚠︎ " + item.text, font: style.bodyFont, color: style.text)
        case .queued, .offline:
            return MarkdownRenderer.plain(item.text, font: style.bodyFont, color: style.text)
        case .qa:
            return qaBody(item, style: style)
        }
    }

    /// Q&A card body: "Q: …" in the secondary color, "A: …" in the primary
    /// color, semibold; "Question declined" when cancelled.
    static func qaBody(_ item: TranscriptItem, style: TranscriptStyle) -> NSAttributedString {
        guard let qa = item.qa else {
            return MarkdownRenderer.plain(item.text, font: style.bodyFont, color: style.text)
        }
        let questionFont = UIFont.systemFont(ofSize: max(11, style.bodyFont.pointSize * 0.9))
        let answerFont = UIFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        if qa.cancelled || qa.items.isEmpty {
            return NSAttributedString(string: qa.cancelled ? "Question declined" : "Question answered",
                                      attributes: [.font: questionFont, .foregroundColor: style.secondaryText])
        }
        let out = NSMutableAttributedString()
        for (index, entry) in qa.items.enumerated() {
            if index > 0 {
                out.append(NSAttributedString(string: "\n\n", attributes: [.font: questionFont]))
            }
            let question = entry.question.hasVisibleCharacters ? entry.question : "Question"
            out.append(NSAttributedString(string: "Q: " + question + "\n",
                                          attributes: [.font: questionFont, .foregroundColor: style.secondaryText]))
            out.append(NSAttributedString(string: "A: " + entry.answer,
                                          attributes: [.font: answerFont, .foregroundColor: style.text]))
        }
        return out
    }

    static func measure(_ string: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        guard string.length > 0, maxWidth > 0 else { return .zero }
        let rect = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       context: nil)
        return CGSize(width: min(maxWidth, ceil(rect.width)), height: ceil(rect.height))
    }

    /// Measure a body; bodies taller than `TextChunker.threshold` are also
    /// segmented, and the returned size is then the exact stack of the
    /// segments' own measurements (what the cell draws).
    static func measureBlock(_ body: NSAttributedString, maxWidth: CGFloat) -> (size: CGSize, chunks: [TextChunker.Chunk]) {
        let size = measure(body, maxWidth: maxWidth)
        guard size.height > TextChunker.threshold else { return (size, []) }
        let chunks = TextChunker.chunks(body, width: maxWidth)
        guard chunks.count > 1 else { return (size, []) }
        var height: CGFloat = 0
        var width: CGFloat = 0
        for chunk in chunks {
            height += chunk.size.height
            width = max(width, chunk.size.width)
        }
        return (CGSize(width: min(maxWidth, width), height: height), chunks)
    }

    /// Stack segment frames top-down inside the text rect.
    static func place(_ chunks: [TextChunker.Chunk], in text: CGRect) -> [RowLayout.Chunk] {
        var out: [RowLayout.Chunk] = []
        out.reserveCapacity(chunks.count)
        var y = text.minY
        for chunk in chunks {
            out.append(RowLayout.Chunk(range: chunk.drawRange,
                                       frame: CGRect(x: text.minX, y: y, width: text.width, height: chunk.size.height)))
            y += chunk.size.height
        }
        return out
    }

    static func footerTitle(for item: TranscriptItem, expanded: Bool) -> String {
        expanded ? "Show less" : "Show all \(lineCount(item.text)) lines"
    }

    /// Pure, thread-safe layout for a row at a given table width.
    static func layout(for item: TranscriptItem, body: NSAttributedString, width: CGFloat,
                       expanded: Bool, style: TranscriptStyle) -> RowLayout {
        typealias M = TranscriptMetrics
        var l = RowLayout()
        l.width = width
        switch item.kind {
        case .user:
            let maxBubble = max(60, width - 2 * M.hPad - M.userLeadingMin)
            let maxText = max(20, maxBubble - 2 * M.bubbleHPad)
            let (size, chunks) = measureBlock(body, maxWidth: maxText)
            let bubbleSize = CGSize(width: size.width + 2 * M.bubbleHPad, height: size.height + 2 * M.bubbleVPad)
            l.bubble = CGRect(x: width - M.hPad - bubbleSize.width, y: M.vPad,
                              width: bubbleSize.width, height: bubbleSize.height)
            l.text = CGRect(x: l.bubble.minX + M.bubbleHPad, y: l.bubble.minY + M.bubbleVPad,
                            width: size.width, height: size.height)
            l.drawWidth = maxText
            l.chunks = place(chunks, in: l.text)
            var bottom = l.bubble.maxY
            if isLongUserText(item) {
                let title = footerTitle(for: item, expanded: expanded)
                let titleWidth = ceil((title as NSString).size(withAttributes: [.font: style.footerFont]).width)
                let footerWidth = titleWidth + 24
                l.footer = CGRect(x: max(M.hPad, l.bubble.minX + 6), y: bottom + M.footerGap,
                                  width: footerWidth, height: M.footerHeight)
                bottom = l.footer.maxY
            }
            l.height = bottom + M.vPad
        case .assistant:
            let maxText = max(20, width - 2 * M.hPad - M.assistantLeading - M.assistantTrailingMin)
            let (size, chunks) = measureBlock(body, maxWidth: maxText)
            l.text = CGRect(x: M.hPad + M.assistantLeading, y: M.vPad, width: size.width, height: size.height)
            l.drawWidth = maxText
            l.chunks = place(chunks, in: l.text)
            l.height = size.height + 2 * M.vPad
        case .error:
            let maxBubble = max(60, width - 2 * M.hPad - M.assistantTrailingMin)
            let maxText = max(20, maxBubble - 2 * M.errorPad)
            let (size, chunks) = measureBlock(body, maxWidth: maxText)
            l.bubble = CGRect(x: M.hPad, y: M.vPad,
                              width: size.width + 2 * M.errorPad, height: size.height + 2 * M.errorPad)
            l.text = CGRect(x: l.bubble.minX + M.errorPad, y: l.bubble.minY + M.errorPad,
                            width: size.width, height: size.height)
            l.drawWidth = maxText
            l.chunks = place(chunks, in: l.text)
            l.height = l.bubble.maxY + M.vPad
        case .queued, .offline:
            let label = item.statusText ?? ""
            let labelWidth = ceil((label as NSString).size(withAttributes: [.font: style.headerFont]).width)
            let headerWidth = M.headerIcon + 5 + labelWidth + (item.cancellable ? 5 + M.headerButton : 0)
            l.header = CGRect(x: width - M.hPad - headerWidth, y: M.vPad,
                              width: headerWidth, height: M.headerHeight)
            let maxBubble = max(60, width - 2 * M.hPad - M.userLeadingMin)
            let maxText = max(20, maxBubble - 2 * M.bubbleHPad)
            let (size, chunks) = measureBlock(body, maxWidth: maxText)
            let bubbleSize = CGSize(width: size.width + 2 * M.bubbleHPad, height: size.height + 2 * M.bubbleVPad)
            l.bubble = CGRect(x: width - M.hPad - bubbleSize.width, y: l.header.maxY + M.headerGap,
                              width: bubbleSize.width, height: bubbleSize.height)
            l.text = CGRect(x: l.bubble.minX + M.bubbleHPad, y: l.bubble.minY + M.bubbleVPad,
                            width: size.width, height: size.height)
            l.drawWidth = maxText
            l.chunks = place(chunks, in: l.text)
            l.height = l.bubble.maxY + M.vPad
        case .qa:
            // Compact left-aligned card: icon + "Answered"/"Declined" header
            // inside the card, then the Q/A lines.
            let maxBubble = max(60, width - 2 * M.hPad - M.assistantTrailingMin)
            let maxText = max(20, maxBubble - 2 * M.bubbleHPad)
            let (size, chunks) = measureBlock(body, maxWidth: maxText)
            let label = item.statusText ?? ""
            let labelWidth = ceil((label as NSString).size(withAttributes: [.font: style.headerFont]).width)
            let headerWidth = min(maxText, M.headerIcon + 5 + labelWidth)
            let contentWidth = max(size.width, headerWidth)
            l.bubble = CGRect(x: M.hPad, y: M.vPad,
                              width: contentWidth + 2 * M.bubbleHPad,
                              height: M.bubbleVPad + M.headerHeight + M.headerGap + size.height + M.bubbleVPad)
            l.header = CGRect(x: l.bubble.minX + M.bubbleHPad, y: l.bubble.minY + M.bubbleVPad,
                              width: headerWidth, height: M.headerHeight)
            l.text = CGRect(x: l.header.minX, y: l.header.maxY + M.headerGap,
                            width: size.width, height: size.height)
            l.drawWidth = maxText
            l.chunks = place(chunks, in: l.text)
            l.height = l.bubble.maxY + M.vPad
        }
        return l
    }

    /// Render + measure one job (thread-safe; runs on the render queue).
    static func run(_ job: Job, width: CGFloat, style: TranscriptStyle,
                    cache: TranscriptBodyCache) -> RowRender {
        let body: NSAttributedString
        if let cached = cache.body(for: job.renderKey) {
            body = cached
        } else {
            body = self.body(for: job.item, expanded: job.expanded, style: style)
            cache.store(body, for: job.renderKey)
        }
        let isLong = isLongUserText(job.item)
        let rowLayout = layout(for: job.item, body: body, width: width, expanded: job.expanded, style: style)
        // Slice segments here (off-main) so the cell only assigns them.
        let segments = rowLayout.chunks.map { body.attributedSubstring(from: $0.range) }
        return RowRender(renderKey: job.renderKey,
                         body: body,
                         layout: rowLayout,
                         footerTitle: isLong ? footerTitle(for: job.item, expanded: job.expanded) : nil,
                         isLong: isLong,
                         segments: segments)
    }
}

/// Thread-safe bounded body cache (NSCache is internally synchronized).
/// Survives transcript re-creation, so reopening a session is instant.
final class TranscriptBodyCache: @unchecked Sendable {
    static let shared = TranscriptBodyCache()
    private let cache = NSCache<NSString, NSAttributedString>()

    private init() {
        cache.countLimit = 1_500
    }

    func body(for key: String) -> NSAttributedString? {
        cache.object(forKey: key as NSString)
    }

    func store(_ body: NSAttributedString, for key: String) {
        cache.setObject(body, forKey: key as NSString)
    }
}

/// Render queue bridge: a dedicated serial queue (bounded, ordered — never
/// floods the cooperative thread pool) awaited via a checked continuation.
enum TranscriptRenderQueue {
    private static let queue = DispatchQueue(label: "remotepi.transcript.render", qos: .userInitiated)

    /// Box so results can cross the queue/actor boundary under Swift 5
    /// Sendable checking (the contents are immutable after creation).
    final class Batch: @unchecked Sendable {
        let jobs: [TranscriptRenderer.Job]
        let width: CGFloat
        let style: TranscriptStyle
        var results: [String: RowRender] = [:]

        init(jobs: [TranscriptRenderer.Job], width: CGFloat, style: TranscriptStyle) {
            self.jobs = jobs
            self.width = width
            self.style = style
        }
    }

    static func render(_ batch: Batch) async -> Batch {
        await withCheckedContinuation { (continuation: CheckedContinuation<Batch, Never>) in
            queue.async {
                var out: [String: RowRender] = [:]
                out.reserveCapacity(batch.jobs.count)
                for job in batch.jobs {
                    out[job.id] = TranscriptRenderer.run(job, width: batch.width, style: batch.style,
                                                         cache: TranscriptBodyCache.shared)
                }
                batch.results = out
                continuation.resume(returning: batch)
            }
        }
    }
}
