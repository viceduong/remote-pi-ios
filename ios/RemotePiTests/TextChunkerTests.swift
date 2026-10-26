import XCTest
import UIKit
@testable import RemotePi

/// Tall-body segmentation (the "Show all N lines" crash fix): chunks must
/// tile the string exactly once, in order, never exceed the hard limit, and
/// stack to the body's exact height.
final class TextChunkerTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 17)
    private let width: CGFloat = 300

    private func attributed(_ text: String) -> NSAttributedString {
        MarkdownRenderer.plain(text, font: font, color: .white)
    }

    private func assertTiles(_ chunks: [TextChunker.Chunk], _ body: NSAttributedString,
                             file: StaticString = #filePath, line: UInt = #line) {
        let ns = body.string as NSString
        var location = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.range.location, location, "chunks must be contiguous", file: file, line: line)
            XCTAssertGreaterThan(chunk.range.length, 0, file: file, line: line)
            XCTAssertEqual(chunk.drawRange.location, chunk.range.location, file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(chunk.drawRange), NSMaxRange(chunk.range), file: file, line: line)
            XCTAssertLessThanOrEqual(chunk.size.height, TextChunker.hardLimit, file: file, line: line)
            if chunk.range.location > 0 {
                XCTAssertEqual(ns.rangeOfComposedCharacterSequence(at: chunk.range.location).location,
                               chunk.range.location, "never split a composed character", file: file, line: line)
            }
            location = NSMaxRange(chunk.range)
        }
        XCTAssertEqual(location, ns.length, "chunks must cover the whole string", file: file, line: line)
    }

    func testShortBodyIsNotSegmented() {
        let body = attributed("hello\nworld")
        let block = TranscriptRenderer.measureBlock(body, maxWidth: width)
        XCTAssertTrue(block.chunks.isEmpty)
        XCTAssertEqual(block.size, TranscriptRenderer.measure(body, maxWidth: width))
    }

    func testLongPasteIsCutAtParagraphsAndStacksToExactHeight() {
        let text = (1...3_000).map { "line \($0): pasted log output" }.joined(separator: "\n")
        let body = attributed(text)
        let total = TranscriptRenderer.measure(body, maxWidth: width).height
        XCTAssertGreaterThan(total, TextChunker.threshold)

        let chunks = TextChunker.chunks(body, width: width)
        XCTAssertGreaterThan(chunks.count, 1)
        assertTiles(chunks, body)
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThan(chunk.size.height, TextChunker.target / 4, "no slivers")
        }
        let sum = chunks.reduce(CGFloat(0)) { $0 + $1.size.height }
        // Paragraph cuts: per-chunk ceil() rounding is the only difference.
        XCTAssertEqual(sum, total, accuracy: CGFloat(chunks.count) * 2 + 2)
        // Paragraph cuts only drop the boundary newline.
        let ns = body.string as NSString
        let drawn = chunks.map { ns.substring(with: $0.drawRange) }.joined(separator: "\n")
        XCTAssertEqual(drawn, text)
    }

    func testGiantSingleParagraphIsCutAtLines() {
        let text = String(repeating: "word ", count: 20_000)
        let body = attributed(text)
        let total = TranscriptRenderer.measure(body, maxWidth: width).height
        let chunks = TextChunker.chunks(body, width: width)
        XCTAssertGreaterThan(chunks.count, 1)
        assertTiles(chunks, body)
        let sum = chunks.reduce(CGFloat(0)) { $0 + $1.size.height }
        XCTAssertEqual(sum, total, accuracy: total * 0.05 + CGFloat(chunks.count) * 2)
    }

    func testEmojiRunNeverSplitsComposedCharacters() {
        let body = attributed(String(repeating: "👩‍👩‍👧‍👦", count: 4_000))
        let chunks = TextChunker.chunks(body, width: width)
        XCTAssertFalse(chunks.isEmpty)
        assertTiles(chunks, body)
    }

    func testExpandedUserRowStacksSegmentsExactly() {
        typealias M = TranscriptMetrics
        let style = TranscriptStyle(theme: .darkGrey, textScale: 1, contentSize: .large)
        let text = (1...2_000).map { "row \($0)" }.joined(separator: "\n")
        let item = TranscriptItem(id: "u1", kind: .user, text: text)
        let expanded = TranscriptRenderer.run(
            TranscriptRenderer.Job(id: "u1", item: item, expanded: true, renderKey: "chunk-test-\(UUID().uuidString)"),
            width: 390, style: style, cache: TranscriptBodyCache.shared)
        let l = expanded.layout
        XCTAssertGreaterThan(l.chunks.count, 1)
        XCTAssertEqual(expanded.segments.count, l.chunks.count)
        XCTAssertEqual(l.chunks.first?.frame.minY ?? -1, l.text.minY, accuracy: 0.001)
        XCTAssertEqual(l.chunks.last?.frame.maxY ?? -1, l.text.maxY, accuracy: 0.001)
        for (a, b) in zip(l.chunks, l.chunks.dropFirst()) {
            XCTAssertEqual(a.frame.maxY, b.frame.minY, accuracy: 0.001)
            XCTAssertLessThanOrEqual(a.frame.height, TextChunker.hardLimit)
        }
        XCTAssertEqual(l.bubble.height, l.text.height + 2 * M.bubbleVPad, accuracy: 0.001)
        XCTAssertEqual(l.height, l.footer.maxY + M.vPad, accuracy: 0.001)

        let collapsed = TranscriptRenderer.run(
            TranscriptRenderer.Job(id: "u1", item: item, expanded: false, renderKey: "chunk-test-\(UUID().uuidString)"),
            width: 390, style: style, cache: TranscriptBodyCache.shared)
        XCTAssertTrue(collapsed.layout.chunks.isEmpty)
        XCTAssertTrue(collapsed.segments.isEmpty)
    }
}
