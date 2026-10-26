import UIKit

/// Draws a pre-rendered attributed string with the SAME string-drawing
/// engine (and wrap width) used to measure it off-main, so text never
/// truncates or reflows differently from the precomputed layout.
final class AttributedTextView: UIView {
    var attributedText: NSAttributedString? {
        didSet {
            if attributedText !== oldValue { setNeedsDisplay() }
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
final class TranscriptCell: UITableViewCell {
    static let reuseId = "TranscriptCell"

    private let bubble = UIView()
    private let textView = AttributedTextView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private let actionButton = HitExpandedButton(type: .system)
    private let footerButton = HitExpandedButton(type: .system)

    private var layout = RowLayout()
    private(set) var kind: TranscriptItem.Kind = .assistant
    private var bubbleColor: UIColor = .clear
    private var bubbleCorner: CGFloat = 0

    var onAction: (() -> Void)?
    var onToggleExpand: (() -> Void)?

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

        headerIcon.contentMode = .scaleAspectFit
        headerIcon.isAccessibilityElement = false
        headerLabel.isAccessibilityElement = false
        contentView.addSubview(headerIcon)
        contentView.addSubview(headerLabel)

        actionButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        contentView.addSubview(actionButton)

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
        onToggleExpand = nil
    }

    func configure(item: TranscriptItem, render: RowRender, style: TranscriptStyle, expanded: Bool) {
        kind = item.kind
        layout = render.layout
        textView.attributedText = render.body
        textView.drawWidth = render.layout.drawWidth

        switch item.kind {
        case .user:
            bubbleColor = style.userBubble
            bubbleCorner = TranscriptMetrics.userCorner
            textView.accessibilityLabel = "You: " + item.text
        case .assistant:
            bubbleColor = .clear
            bubbleCorner = 0
            textView.accessibilityLabel = "Assistant: " + item.text
        case .error:
            bubbleColor = style.errorBackground
            bubbleCorner = TranscriptMetrics.errorCorner
            textView.accessibilityLabel = "Error: " + item.text
        case .queued:
            bubbleColor = style.chipBackground
            bubbleCorner = TranscriptMetrics.userCorner
            textView.accessibilityLabel = "Queued message, \(item.statusText ?? "queued"): " + item.text
        case .offline:
            bubbleColor = style.offlineBackground
            bubbleCorner = TranscriptMetrics.userCorner
            textView.accessibilityLabel = "Unsent message, waiting for connection: " + item.text
        }
        bubble.backgroundColor = bubbleColor
        bubble.layer.cornerRadius = bubbleCorner
        bubble.isHidden = render.layout.bubble == .zero

        let isChip = item.kind == .queued || item.kind == .offline
        headerIcon.isHidden = !isChip
        headerLabel.isHidden = !isChip
        actionButton.isHidden = !(isChip && item.cancellable)
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
        textView.frame = l.text
        if !headerIcon.isHidden {
            let h = l.header
            let m = TranscriptMetrics.self
            headerIcon.frame = CGRect(x: h.minX, y: h.midY - m.headerIcon / 2,
                                      width: m.headerIcon, height: m.headerIcon)
            let buttonSpace = actionButton.isHidden ? 0 : 5 + m.headerButton
            let labelX = headerIcon.frame.maxX + 5
            headerLabel.frame = CGRect(x: labelX, y: h.minY,
                                       width: max(0, h.maxX - buttonSpace - labelX), height: h.height)
            actionButton.frame = CGRect(x: h.maxX - m.headerButton, y: h.midY - m.headerButton / 2,
                                        width: m.headerButton, height: m.headerButton)
        }
        if !footerButton.isHidden {
            footerButton.frame = l.footer
        }
    }

    /// Frame (contentView coordinates) used for the context-menu preview.
    var previewFrame: CGRect {
        layout.bubble != .zero ? layout.bubble : layout.text.insetBy(dx: -6, dy: -4)
    }

    /// A fresh, UN-transformed copy of the row's bubble for the context-menu
    /// preview (snapshots of the flipped contentView would render upside
    /// down).
    func makePreviewView() -> UIView {
        let frame = previewFrame
        let container = UIView(frame: CGRect(origin: .zero, size: frame.size))
        container.backgroundColor = bubbleColor == .clear ? (superview?.backgroundColor ?? .systemBackground) : bubbleColor
        container.layer.cornerRadius = max(bubbleCorner, 10)
        container.layer.cornerCurve = .continuous
        let copy = AttributedTextView(frame: CGRect(x: layout.text.minX - frame.minX,
                                                    y: layout.text.minY - frame.minY,
                                                    width: layout.text.width,
                                                    height: layout.text.height))
        copy.drawWidth = layout.drawWidth
        copy.attributedText = textView.attributedText
        container.addSubview(copy)
        return container
    }

    var previewCornerRadius: CGFloat { max(bubbleCorner, 10) }

    @objc private func actionTapped() { onAction?() }
    @objc private func footerTapped() { onToggleExpand?() }
}
