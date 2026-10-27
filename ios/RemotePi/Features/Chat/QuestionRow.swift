import SwiftUI
import UIKit

/// Transcript row hosting the pending `ask_user_question` card (SwiftUI) in a
/// child `UIHostingController` (iOS 15 has no `UIHostingConfiguration`).
///
/// - Like every transcript row, `contentView` is flipped back (scaleY -1)
///   inside the flipped table, so the hosted view renders upright (the two
///   transforms cancel; `convert(_:to:)` to the window is identity-scaled).
/// - The hosted card observes the `ChatViewModel` itself (selections, typed
///   text), so interaction never reloads/reconfigures this row — the table
///   only sets a new root view when the QUESTION (or theme) changes
///   (`contentKey`), which keeps the text field's focus while typing.
/// - Safe-area / keyboard avoidance of the inner hosting controller is
///   disabled: the table, not the card, moves for the keyboard.
final class QuestionCell: UITableViewCell {
    static let reuseId = "QuestionCell"

    let host = UIHostingController(rootView: AnyView(EmptyView()))
    /// Identity of the hosted content (question + style); nil = empty.
    private(set) var contentKey: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        // A container, not one element: VoiceOver must reach the card's
        // options, text fields and buttons individually.
        isAccessibilityElement = false
        // Inverted transcript: the table is flipped, each row flips back.
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        contentView.addSubview(host.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Install the card for `key` (no-op when it is already showing — the
    /// hosted view updates itself from the view model).
    func configure(key: String, makeRoot: () -> AnyView) {
        guard key != contentKey else { return }
        contentKey = key
        host.rootView = makeRoot()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if host.view.frame != contentView.bounds {
            host.view.frame = contentView.bounds
        }
    }

    // MARK: Child view-controller containment

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard host.parent == nil, let parent = Self.owningViewController(of: self) else { return }
            parent.addChild(host)
            host.didMove(toParent: parent)
        } else if host.parent != nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        }
    }

    private static func owningViewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// The focused text input inside the card, if any.
    var focusedInput: UIView? {
        func find(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews {
                if let hit = find(sub) { return hit }
            }
            return nil
        }
        return find(host.view)
    }
}

/// Builds the hosted question card with an EXPLICIT environment (theme,
/// color scheme, Dynamic Type): the hosting controllers live outside the
/// SwiftUI tree, and the measuring controller is not even in a window, so
/// nothing may be inherited implicitly (measured height == displayed height).
@MainActor
enum QuestionRowContent {
    static func root(_ content: AnyView, style: TranscriptStyle) -> some View {
        content
            .environment(\.theme, style.theme)
            .environment(\.colorScheme, style.theme.scheme)
            .dynamicTypeSize(dynamicTypeSize(for: style.contentSize))
    }

    /// Displayed: top-aligned, ignoring safe areas and the keyboard.
    static func display(_ content: AnyView, style: TranscriptStyle) -> AnyView {
        AnyView(root(content, style: style)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea())
    }

    /// Measured: natural height at a fixed width.
    static func measuring(_ content: AnyView, style: TranscriptStyle, width: CGFloat) -> AnyView {
        AnyView(root(content, style: style)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
    }

    /// UIKit → SwiftUI size category (iOS 15-safe manual mapping).
    static func dynamicTypeSize(for category: UIContentSizeCategory) -> DynamicTypeSize {
        switch category {
        case .extraSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .xLarge
        case .extraExtraLarge: return .xxLarge
        case .extraExtraExtraLarge: return .xxxLarge
        case .accessibilityMedium: return .accessibility1
        case .accessibilityLarge: return .accessibility2
        case .accessibilityExtraLarge: return .accessibility3
        case .accessibilityExtraExtraLarge: return .accessibility4
        case .accessibilityExtraExtraExtraLarge: return .accessibility5
        default: return .large
        }
    }
}
