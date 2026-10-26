import UIKit

/// Draws a pre-rendered attributed string with the SAME string-drawing
/// engine (and wrap width) used to measure it off-main, so text never
/// truncates or reflows differently from the precomputed layout.
///
/// Its backing store is the size of its bounds, so a view is never given
/// more than one segment of a tall body (see `TextChunker`).
final class AttributedTextView: UIView {
    var attributedText: NSAttributedString? {
        didSet {
            guard attributedText !== oldValue else { return }
            // A re-render with identical content (e.g. earlier segments of a
            // streaming reply) must not redraw.
            if let new = attributedText, let old = oldValue, new.isEqual(to: old) { return }
            setNeedsDisplay()
        }
    }

    var drawWidth: CGFloat = 0 {
        didSet {
            if drawWidth != oldValue { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let attributedText, attributedText.length > 0 else { return }
        let width = drawWidth > 0 ? drawWidth : bounds.width
        attributedText.draw(with: CGRect(x: 0, y: 0, width: width, height: bounds.height + 64),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil)
    }
}

/// Small controls get a 44pt minimum hit target (HIG) without changing
/// their visual size.
final class HitExpandedButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2)
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// One transcript row. Plain UIKit, manual frames from the precomputed
/// `RowLayout`; no gestures besides real buttons (the context menu is
/// provided by the table delegate), so scrolling always starts instantly.
///
/// Tall bodies (`layout.chunks` non-empty) are drawn by a small pool of
/// segment views materialized only near the visible viewport — memory stays
/// bounded however tall the row is (an expanded 5,000-line paste).
final class TranscriptCell: UITableViewCell {
    static let reuseId = "TranscriptCell"
    /// Segments within this distance of the viewport keep their content.
    static let segmentMargin: CGFloat = 400

    private let bubble = UIView()
    private let textView = AttributedTextView()
    /// Accessibility element covering a segmented body (plain view: no
    /// drawing, no backing store).
    private let segmentedAccessibility = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private let actionButton = HitExpandedButton(type: .system)
    private let steerButton = HitExpandedButton(type: .system)
    private let footerButton = HitExpandedButton(type: .system)

    private var layout = RowLayout()
    private(set) var kind: TranscriptItem.Kind = .assistant
    private var bubbleColor: UIColor = .clear
    private var bubbleCorner: CGFloat = 0
    private var fullBody: NSAttributedString?
    private var segments: [NSAttributedString] = []
    private var activeSegmentViews: [Int: AttributedTextView] = [:]
    private var freeSegmentViews: [AttributedTextView] = []

    var onAction: (() -> Void)?
    var onSteer: (() -> Void)?
    var onToggleExpand: (() -> Void)?

    /// Row body is drawn as stacked segments.
    var isSegmented: Bool { !segments.isEmpty }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        // Inverted transcript: the table is flipped, each row flips back.
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        bubble.isUserInteractionEnabled = false
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)
        contentView.addSubview(textView)

        segmentedAccessibility.isUserInteractionEnabled = false
        segmentedAccessibility.isAccessibilityElement = true
        segmentedAccessibility.accessibilityTraits = .staticText
        segmentedAccessibility.isHidden = true
        contentView.addSubview(segmentedAccessibility)

        headerIcon.contentMode = .scaleAspectFit
        headerIcon.isAccessibilityElement = false
        headerLabel.isAccessibilityElement = false
        contentView.addSubview(headerIcon)
        contentView.addSubview(headerLabel)

        actionButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        contentView.addSubview(actionButton)

        steerButton.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        steerButton.addTarget(self, action: #selector(steerTapped), for: .touchUpInside)
        contentView.addSubview(steerButton)

        footerButton.contentHorizontalAlignment = .leading
        footerButton.addTarget(self, action: #selector(footerTapped), for: .touchUpInside)
        contentView.addSubview(footerButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        onSteer = nil
        onToggleExpand = nil
        // Free segment backing stores right away (the next row may be short).
        recycleAllSegments()
    }

    func configure(item: TranscriptItem, render: RowRender, style: TranscriptStyle, expanded: Bool) {
        kind = item.kind
        layout = render.layout
        fullBody = render.body
        segments = render.layout.chunks.count == render.segments.count ? render.segments : []

        let accessibilityText: String
        switch item.kind {
        case .user:
            bubbleColor = style.userBubble
            bubbleCorner = TranscriptMetrics.userCorner
            accessibilityText = "You: " + item.text
        case .assistant:
            bubbleColor = .clear
            bubbleCorner = 0
            accessibilityText = "Assistant: " + item.text
        case .error:
            bubbleColor = style.errorBackground
            bubbleCorner = TranscriptMetrics.errorCorner
            accessibilityText = "Error: " + item.text
        case .queued:
            bubbleColor = style.chipBackground
            bubbleCorner = TranscriptMetrics.userCorner
            accessibilityText = "Queued message, \(item.statusText ?? "queued"): " + item.text
        case .offline:
            bubbleColor = style.offlineBackground
            bubbleCorner = TranscriptMetrics.userCorner
            accessibilityText = "Unsent message, waiting for connection: " + item.text
        case .qa:
            bubbleColor = style.secondaryBackground
            bubbleCorner = TranscriptMetrics.errorCorner
            accessibilityText = item.qa?.cancelled == true
                ? "Question declined"
                : "Question answered. " + item.text
        }
        bubble.backgroundColor = bubbleColor
        bubble.layer.cornerRadius = bubbleCorner
        bubble.isHidden = render.layout.bubble == .zero

        if segments.isEmpty {
            recycleAllSegments()
            textView.isHidden = false
            textView.attributedText = render.body
            textView.drawWidth = render.layout.drawWidth
            textView.accessibilityLabel = accessibilityText
            segmentedAccessibility.isHidden = true
        } else {
            textView.isHidden = true
            textView.attributedText = nil
            segmentedAccessibility.isHidden = false
            segmentedAccessibility.accessibilityLabel = accessibilityText
            // Re-point already materialized segments at the new slices
            // (identical slices don't redraw); `layoutSubviews` fixes the set.
            for (index, view) in activeSegmentViews {
                if index < segments.count {
                    view.attributedText = segments[index]
                    view.drawWidth = layout.drawWidth
                } else {
                    activeSegmentViews[index] = nil
                    recycle(view)
                }
            }
        }

        let isChip = item.kind == .queued || item.kind == .offline
        let hasHeader = isChip || item.kind == .qa
        headerIcon.isHidden = !hasHeader
        headerLabel.isHidden = !hasHeader
        actionButton.isHidden = !(isChip && item.cancellable)
        steerButton.isHidden = !(item.kind == .queued && item.canSteer)
        if isChip {
            let tint = item.kind == .queued ? style.chipTint : style.secondaryText
            headerIcon.image = UIImage(systemName: item.kind == .queued ? "clock.arrow.circlepath" : "wifi.slash")
            headerIcon.tintColor = tint
            headerLabel.text = item.statusText
            headerLabel.font = style.headerFont
            headerLabel.textColor = tint
            actionButton.tintColor = style.secondaryText
            actionButton.accessibilityLabel = item.kind == .queued
                ? "Cancel queued message" : "Discard unsent message"
            steerButton.tintColor = style.accent
            steerButton.accessibilityLabel = "Send now"
            steerButton.accessibilityHint = "Interrupts the agent and sends this message immediately"
        } else if item.kind == .qa {
            let tint = item.qa?.cancelled == true ? style.secondaryText : style.accent
            headerIcon.image = UIImage(systemName: "questionmark.bubble")
            headerIcon.tintColor = tint
            headerLabel.text = item.statusText
            headerLabel.font = style.headerFont
            headerLabel.textColor = tint
        }

        if let title = render.footerTitle {
            footerButton.isHidden = false
            let image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(font: style.footerFont))
            footerButton.setImage(image, for: .normal)
            footerButton.setTitle(" " + title, for: .normal)
            footerButton.titleLabel?.font = style.footerFont
            footerButton.tintColor = style.secondaryText
            footerButton.accessibilityLabel = title
        } else {
            footerButton.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let l = layout
        bubble.frame = l.bubble
        // Hidden draw views get a zero frame: no backing store at all.
        textView.frame = textView.isHidden ? .zero : l.text
        segmentedAccessibility.frame = segmentedAccessibility.isHidden ? .zero : l.text
        if !headerIcon.isHidden {
            let h = l.header
            let m = TranscriptMetrics.self
            headerIcon.frame = CGRect(x: h.minX, y: h.midY - m.headerIcon / 2,
                                      width: m.headerIcon, height: m.headerIcon)
            // Right-align the action buttons (✕ at the far edge, then "send
            // now" to its left); the label fills the gap up to the leftmost one.
            var rightEdge = h.maxX
            if !actionButton.isHidden {
                actionButton.frame = CGRect(x: rightEdge - m.headerButton, y: h.midY - m.headerButton / 2,
                                            width: m.headerButton, height: m.headerButton)
                rightEdge = actionButton.frame.minX - 5
            }
            if !steerButton.isHidden {
                steerButton.frame = CGRect(x: rightEdge - m.headerButton, y: h.midY - m.headerButton / 2,
                                           width: m.headerButton, height: m.headerButton)
                rightEdge = steerButton.frame.minX - 5
            }
            let labelX = headerIcon.frame.maxX + 5
            headerLabel.frame = CGRect(x: labelX, y: h.minY,
                                       width: max(0, rightEdge - labelX), height: h.height)
        }
        if !footerButton.isHidden {
            footerButton.frame = l.footer
        }
        updateVisibleSegments()
    }

    // MARK: Segments (tall bodies)

    /// Materialize the segments near the table's viewport, release the rest.
    /// Called on layout and by the table on scroll / willDisplay.
    func updateVisibleSegments() {
        let chunks = layout.chunks
        guard !segments.isEmpty, chunks.count == segments.count else {
            recycleAllSegments()
            return
        }
        // Not in a table yet: keep what we have until the next layout pass.
        guard let scrollView = enclosingScrollView() else { return }
        // Both the table and contentView are flipped; `convert` applies both.
        let visible = contentView.convert(scrollView.bounds, from: scrollView)
        let minY = visible.minY - Self.segmentMargin
        let maxY = visible.maxY + Self.segmentMargin
        var wanted: [Int] = []
        for (index, chunk) in chunks.enumerated() where chunk.frame.maxY >= minY && chunk.frame.minY <= maxY {
            wanted.append(index)
        }
        let wantedSet = Set(wanted)
        for (index, view) in activeSegmentViews where !wantedSet.contains(index) {
            activeSegmentViews[index] = nil
            recycle(view)
        }
        for index in wanted {
            let view = activeSegmentViews[index] ?? dequeueSegmentView()
            activeSegmentViews[index] = view
            if view.frame != chunks[index].frame { view.frame = chunks[index].frame }
            view.drawWidth = layout.drawWidth
            view.attributedText = segments[index]
            view.isHidden = false
        }
    }

    private func enclosingScrollView() -> UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    private func dequeueSegmentView() -> AttributedTextView {
        if let view = freeSegmentViews.popLast() { return view }
        let view = AttributedTextView()
        view.isAccessibilityElement = false
        contentView.insertSubview(view, aboveSubview: textView)
        return view
    }

    private func recycle(_ view: AttributedTextView) {
        view.attributedText = nil
        view.isHidden = true
        view.frame = .zero
        view.layer.contents = nil
        freeSegmentViews.append(view)
    }

    private func recycleAllSegments() {
        guard !activeSegmentViews.isEmpty else { return }
        for view in activeSegmentViews.values { recycle(view) }
        activeSegmentViews.removeAll()
    }

    // MARK: Context-menu preview

    /// Frame (contentView coordinates) used for the context-menu preview —
    /// capped to the first `previewMaxTextHeight` of the body.
    var previewFrame: CGRect {
        var frame = layout.bubble != .zero ? layout.bubble : layout.text.insetBy(dx: -6, dy: -4)
        let excess = layout.text.height - TranscriptMetrics.previewMaxTextHeight
        if excess > 0 { frame.size.height -= excess }
        return frame
    }

    /// A fresh, UN-transformed copy of the row's bubble for the context-menu
    /// preview (snapshots of the flipped contentView would render upside
    /// down). Never taller than `previewFrame`, whatever the row height.
    func makePreviewView() -> UIView {
        let frame = previewFrame
        let container = UIView(frame: CGRect(origin: .zero, size: frame.size))
        container.backgroundColor = bubbleColor == .clear ? (superview?.backgroundColor ?? .systemBackground) : bubbleColor
        container.layer.cornerRadius = max(bubbleCorner, 10)
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        let copy = AttributedTextView(frame: CGRect(x: layout.text.minX - frame.minX,
                                                    y: layout.text.minY - frame.minY,
                                                    width: layout.text.width,
                                                    height: min(layout.text.height, TranscriptMetrics.previewMaxTextHeight)))
        copy.drawWidth = layout.drawWidth
        copy.attributedText = segments.first ?? fullBody
        container.addSubview(copy)
        if kind == .qa, !headerIcon.isHidden {
            let icon = UIImageView(image: headerIcon.image)
            icon.tintColor = headerIcon.tintColor
            icon.contentMode = .scaleAspectFit
            icon.frame = headerIcon.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let label = UILabel(frame: headerLabel.frame.offsetBy(dx: -frame.minX, dy: -frame.minY))
            label.text = headerLabel.text
            label.font = headerLabel.font
            label.textColor = headerLabel.textColor
            container.addSubview(icon)
            container.addSubview(label)
        }
        return container
    }

    var previewCornerRadius: CGFloat { max(bubbleCorner, 10) }

    @objc private func actionTapped() { onAction?() }
    @objc private func steerTapped() { onSteer?() }
    @objc private func footerTapped() { onToggleExpand?() }
}
