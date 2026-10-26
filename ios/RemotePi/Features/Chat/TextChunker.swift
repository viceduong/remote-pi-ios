import UIKit

/// Splits a tall attributed body into vertically stacked segments, so no
/// single view — and so no single layer backing store — is taller than about
/// a screen. (One `draw(_:)` view per row made an expanded multi-thousand
/// line paste allocate a backing store of hundreds of MB → jetsam / CA
/// failure.)
///
/// Pure and thread-safe: runs on the transcript render queue. TextKit only
/// PICKS the cut points (paragraph starts, else line starts); every segment
/// is then measured with the SAME string-drawing call the cell draws it
/// with, so the stacked heights are exact.
enum TextChunker {
    struct Chunk: Equatable {
        /// Coverage: chunks tile the string exactly once, in order.
        let range: NSRange
        /// What is drawn/measured: `range` minus its trailing newline.
        let drawRange: NSRange
        let size: CGSize
    }

    /// Bodies taller than this are segmented.
    static let threshold: CGFloat = 1_200
    /// Target segment height.
    static let target: CGFloat = 1_000
    /// No segment may be taller than this (split further by characters).
    static let hardLimit: CGFloat = 2_000

    /// Segment `string` wrapped at `width`. Always returns at least one chunk
    /// for a non-empty string (callers decide via `threshold` whether to use
    /// segmentation at all).
    static func chunks(_ string: NSAttributedString, width: CGFloat) -> [Chunk] {
        let ns = string.string as NSString
        guard ns.length > 0, width > 0 else { return [] }
        var result: [Chunk] = []
        for range in cutRanges(string, ns: ns, width: width) {
            let chunk = make(string, ns: ns, range: range, width: width)
            if chunk.size.height > hardLimit {
                result.append(contentsOf: splitByCharacters(string, ns: ns, range: range, width: width))
            } else {
                result.append(chunk)
            }
        }
        return result
    }

    // MARK: - Cut points (TextKit, off-main, confined to this call)

    /// Ranges tiling the whole string, each ~`target` tall. Cuts prefer
    /// paragraph starts (backing up to the current paragraph's start when
    /// that keeps at least half a target); otherwise a line-fragment start.
    private static func cutRanges(_ string: NSAttributedString, ns: NSString, width: CGFloat) -> [NSRange] {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let glyphCount = manager.numberOfGlyphs
        let target = Self.target
        let length = ns.length
        var cuts: [Int] = [0]
        if glyphCount > 0 {
            var chunkTop: CGFloat = 0
            var paragraphCut: (index: Int, y: CGFloat)?
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) { rect, _, _, glyphRange, _ in
                let index = manager.characterIndexForGlyph(at: glyphRange.location)
                let lastCut = cuts[cuts.count - 1]
                guard index > lastCut, index < length else { return }
                let startsParagraph = ns.character(at: index - 1) == 0x0A
                if rect.maxY - chunkTop > target {
                    if !startsParagraph, let p = paragraphCut, p.y - chunkTop >= target / 2 {
                        // Mid-paragraph overflow: back up to that paragraph's start.
                        cuts.append(p.index)
                        chunkTop = p.y
                    } else {
                        // This line starts a paragraph, or the paragraph is
                        // too tall to keep whole: cut at this line.
                        cuts.append(index)
                        chunkTop = rect.minY
                    }
                    paragraphCut = nil
                }
                if startsParagraph, index > cuts[cuts.count - 1] {
                    paragraphCut = (index, rect.minY)
                }
            }
        }
        var ranges: [NSRange] = []
        ranges.reserveCapacity(cuts.count)
        for (i, start) in cuts.enumerated() {
            let end = i + 1 < cuts.count ? cuts[i + 1] : length
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
        }
        return ranges
    }

    // MARK: - Fallback: character ranges (one giant unbreakable run)

    /// Split `range` into pieces of at most a few thousand characters, halving
    /// a piece until it measures within `hardLimit`. Never splits a composed
    /// character sequence (emoji, combining marks, CRLF).
    private static func splitByCharacters(_ string: NSAttributedString, ns: NSString,
                                          range: NSRange, width: CGFloat) -> [Chunk] {
        var out: [Chunk] = []
        let end = NSMaxRange(range)
        var location = range.location
        var budget = 4_000
        while location < end {
            var length = min(budget, end - location)
            if location + length < end {
                let composed = ns.rangeOfComposedCharacterSequence(at: location + length)
                length = composed.location > location
                    ? composed.location - location
                    : NSMaxRange(composed) - location
            }
            let piece = make(string, ns: ns, range: NSRange(location: location, length: length), width: width)
            if piece.size.height > hardLimit, budget > 1 {
                budget = max(1, length / 2)
                continue
            }
            out.append(piece)
            location += length
        }
        return out
    }

    // MARK: - Measuring

    static func drawRange(_ ns: NSString, _ range: NSRange) -> NSRange {
        var length = range.length
        if length > 1, ns.character(at: range.location + length - 1) == 0x0A { length -= 1 }
        if length > 1, ns.character(at: range.location + length - 1) == 0x0D { length -= 1 }
        return NSRange(location: range.location, length: length)
    }

    private static func make(_ string: NSAttributedString, ns: NSString, range: NSRange, width: CGFloat) -> Chunk {
        let draw = drawRange(ns, range)
        let size = TranscriptRenderer.measure(string.attributedSubstring(from: draw), maxWidth: width)
        return Chunk(range: range, drawRange: draw, size: size)
    }
}
