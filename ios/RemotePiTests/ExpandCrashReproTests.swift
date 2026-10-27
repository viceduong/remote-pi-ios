import XCTest
import Combine
import UIKit
@testable import RemotePi

/// Reproduction harness for "tapping 'Show all N lines' on a collapsed long
/// user message crashes the app". Drives the REAL transcript (inverted table,
/// diffable data source, off-main render, segmented bodies) in a visible
/// window and taps the real footer button, then collapses and scrolls.
@MainActor
final class ExpandCrashReproTests: XCTestCase {
    private var window: UIWindow!
    private var transcript: TranscriptContainerView!
    private var subject: CurrentValueSubject<[TranscriptItem], Never>!

    override func setUp() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        let style = TranscriptStyle(theme: .darkGrey, textScale: 1, contentSize: .large)
        transcript = TranscriptContainerView(style: style)
        transcript.frame = host.view.bounds
        host.view.addSubview(transcript)
        subject = CurrentValueSubject([])
        transcript.bind(transcript: subject.eraseToAnyPublisher(),
                        scrollRequests: Empty<Void, Never>().eraseToAnyPublisher())
    }

    override func tearDown() async throws {
        transcript?.teardown()
        window?.isHidden = true
        window = nil
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Current physical footprint (what jetsam limits), in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Spin until `condition` holds (or timeout), sampling peak footprint.
    @discardableResult
    private func wait(_ label: String, timeout: TimeInterval, _ condition: () -> Bool) -> (ok: Bool, seconds: Double, peakMB: Double) {
        let start = Date()
        var peak = Self.footprintMB()
        var maxStall: Double = 0
        while Date().timeIntervalSince(start) < timeout {
            if condition() { break }
            let tick = Date()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            maxStall = max(maxStall, Date().timeIntervalSince(tick))
            peak = max(peak, Self.footprintMB())
        }
        NSLog("[repro] %@: longest main-thread stall %.2fs", label, maxStall)
        let ok = condition()
        let secs = Date().timeIntervalSince(start)
        NSLog("[repro] \(label): ok=\(ok) t=\(String(format: "%.2f", secs))s peak=\(Int(peak))MB")
        return (ok, secs, peak)
    }

    private func footerButtons() -> [UIButton] {
        func walk(_ v: UIView) -> [UIButton] {
            var out: [UIButton] = []
            if let b = v as? UIButton, !b.isHidden,
               let t = b.title(for: .normal), t.contains("Show all") || t.contains("Show less") {
                out.append(b)
            }
            for s in v.subviews { out += walk(s) }
            return out
        }
        return walk(transcript.tableView)
    }

    private func items(userText: String) -> [TranscriptItem] {
        [
            TranscriptItem(id: "a0", kind: .assistant, text: "Earlier reply.\nWith two lines."),
            TranscriptItem(id: "u1", kind: .user, text: userText, entryId: "e1"),
            TranscriptItem(id: "a1", kind: .assistant, text: "Got it — looking at the log now."),
        ]
    }

    /// Expand → collapse → expand, scroll through, for one body shape.
    private func exercise(_ label: String, text: String) {
        subject.send(items(userText: text))
        NSLog("[repro] \(label): base footprint=\(Int(Self.footprintMB()))MB")
        wait("\(label) collapsed render", timeout: 60) { !footerButtons().isEmpty }
        guard let button = footerButtons().first else {
            return XCTFail("\(label): no 'Show all' footer rendered")
        }
        NSLog("[repro] \(label): tapping '\(button.title(for: .normal) ?? "")'")
        button.sendActions(for: .touchUpInside)
        let expanded = wait("\(label) expand", timeout: 120) {
            footerButtons().contains { $0.title(for: .normal)?.contains("Show less") == true }
        }
        XCTAssertTrue(expanded.ok, "\(label): row did not expand")
        // Scroll the whole expanded row through the viewport (segments churn).
        let table = transcript.tableView
        let maxY = max(0, table.contentSize.height - table.bounds.height)
        var y: CGFloat = table.contentOffset.y
        while y < maxY {
            y = min(maxY, y + 600)
            table.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            spin(0.02)
        }
        NSLog("[repro] \(label): expanded height=\(table.contentSize.height) footprint=\(Int(Self.footprintMB()))MB")
        footerButtons().first?.sendActions(for: .touchUpInside)
        spin(1.0)
        footerButtons().first?.sendActions(for: .touchUpInside)
        spin(1.0)
        // A live update while expanded (streaming reply below it).
        var next = items(userText: text)
        next[2].text += " More text."
        subject.send(next)
        spin(0.8)
        NSLog("[repro] \(label): ok")
    }

    func testExpandManyShortLines() {
        exercise("400 short lines", text: (1...400).map { "line \($0): ok" }.joined(separator: "\n"))
    }

    func testExpandLogPaste() {
        let line = "2026-10-27T10:00:00.123Z ERROR [worker-3] request failed: connect ECONNREFUSED 127.0.0.1:5432 (retry 3/5)"
        exercise("log paste 3000 lines", text: (1...3000).map { "\($0) \(line)" }.joined(separator: "\n"))
    }

    func testExpandJustOverThreshold() {
        exercise("25 lines", text: (1...25).map { "row \($0)" }.joined(separator: "\n"))
    }

    func testExpandSingleGiantLine() {
        exercise("one 40k-char line", text: String(repeating: "abcdefghij ", count: 4_000))
    }

    func testExpandNoSpacesGiantLine() {
        exercise("one 30k-char word", text: String(repeating: "x", count: 30_000) + "\n" + (1...30).map(String.init).joined(separator: "\n"))
    }

    func testExpandCRLFAndEmoji() {
        exercise("CRLF + emoji", text: (1...300).map { "👋🏽 line \($0) — ünïcödé ✓" }.joined(separator: "\r\n"))
    }

    func testExpandBlankLineHeavy() {
        exercise("blank lines", text: (1...200).map { $0 % 3 == 0 ? "" : "text \($0)" }.joined(separator: "\n\n"))
    }

    func testExpandCodeBlock() {
        let code = "```swift\n" + (1...500).map { "    let value\($0) = compute(\($0)) // comment" }.joined(separator: "\n") + "\n```"
        exercise("code fence", text: code)
    }
}
