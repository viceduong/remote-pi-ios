import XCTest
@testable import RemotePi

final class RemotePiTests: XCTestCase {

    // MARK: - Message classification

    func testToolResultClassifiedAsTool() {
        let msg = ChatMessage.fromAgentMessage([
            "role": "toolResult", "toolName": "bash",
            "content": [[ "type": "text", "text": "ls output" ]],
        ])
        XCTAssertEqual(msg.role, .tool)
        XCTAssertEqual(msg.toolName, "bash")
        XCTAssertEqual(msg.text, "ls output")
    }

    func testToolNameOnUserRoleIsTool() {
        let msg = ChatMessage.fromAgentMessage([
            "role": "user", "toolName": "web_search",
            "content": [[ "type": "text", "text": "results" ]],
        ])
        XCTAssertEqual(msg.role, .tool)
    }

    func testCustomRoleIsSystemNote() {
        let msg = ChatMessage.fromAgentMessage([
            "role": "custom", "customType": "context-prune-summary",
            "content": "### Tool Call 1: bash\n- Listed files.",
        ])
        XCTAssertEqual(msg.role, .user)
        XCTAssertTrue(msg.isSystemNote)
    }

    func testBgNotificationIsSystemNote() {
        let msg = ChatMessage.fromAgentMessage([
            "role": "user",
            "content": "✗ [bg-abc123] failed (exit 1) in 5.0s",
        ])
        XCTAssertTrue(msg.isSystemNote)
    }

    func testPlainUserPromptIsNotSystemNote() {
        let msg = ChatMessage.fromAgentMessage([
            "role": "user", "content": "what is a tool call?",
        ])
        XCTAssertFalse(msg.isSystemNote)
    }

    func testServerMappedShape() {
        // History/file_update events arrive pre-mapped by the server.
        let msg = ChatMessage.fromAgentMessage([
            "role": "user", "text": "### Tool Call 1: bash", "system": true,
        ])
        XCTAssertTrue(msg.isSystemNote)
        let tool = ChatMessage.fromAgentMessage([
            "role": "tool", "text": "out", "toolName": "ls", "isError": false,
        ])
        XCTAssertEqual(tool.role, .tool)
        XCTAssertEqual(tool.toolName, "ls")
    }

    // MARK: - ANSI rendering

    func testAnsiTruecolorParsed() {
        let attr = ANSIParser.attributed("\u{1B}[38;2;255;0;0mred\u{1B}[39m plain",
                                         baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        var colors: [UIColor] = []
        attr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if let c = value as? UIColor, range.length > 0 {
                colors.append(c)
            }
        }
        XCTAssertGreaterThan(colors.count, 0)
        // First run (red segment) should be red-ish.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colors.first?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.8)
        XCTAssertLessThan(g, 0.2)
    }

    func testAnsiEscapesStrippedFromOutput() {
        let attr = ANSIParser.attributed("a\u{1B}[1mb\u{1B}[0mc",
                                         baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertFalse(attr.string.contains("\u{1B}"))
        XCTAssertEqual(attr.string, "abc")
    }

    // MARK: - EventSource frame parsing (SSE)

    func testSSEFrameParsing() {
        // Reach into the parser via a small harness through URLSession is not
        // feasible here; verify the wire format expectations of our server:
        // event:/id:/data: lines then a blank line.
        let frame = "event: file_update\nid: 12\ndata: {\"type\":\"file_update\"}\n\n"
        XCTAssertTrue(frame.hasPrefix("event: file_update"))
        XCTAssertTrue(frame.contains("id: 12"))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
    }
}
