import SwiftUI
import UIKit
import Combine

/// Callbacks from the UIKit transcript into the chat view model / screen.
struct TranscriptActions {
    var loadMore: @MainActor () -> Void = {}
    var nearBottomChanged: @MainActor (Bool) -> Void = { _ in }
    var cancelQueued: @MainActor (String) -> Void = { _ in }
    var steerQueued: @MainActor (String) -> Void = { _ in }
    var discardOffline: @MainActor (String) -> Void = { _ in }
    var fork: @MainActor (String) -> Void = { _ in }
    var selectText: @MainActor (String) -> Void = { _ in }
}

/// SwiftUI bridge for the UIKit transcript. Data does NOT flow through
/// `updateUIView` — the container subscribes to the view model's transcript
/// subject directly, so SwiftUI re-renders never touch the table.
struct TranscriptView: UIViewRepresentable {
    let viewModel: ChatViewModel
    let theme: AppTheme
    let textScale: Double
    let contentSize: UIContentSizeCategory
    let actions: TranscriptActions

    func makeUIView(context: Context) -> TranscriptContainerView {
        let view = TranscriptContainerView(style: TranscriptStyle(theme: theme, textScale: textScale,
                                                                  contentSize: contentSize))
        view.actions = actions
        view.bind(transcript: viewModel.transcript.eraseToAnyPublisher(),
                  scrollRequests: viewModel.scrollToBottomRequests.eraseToAnyPublisher())
        return view
    }

    func updateUIView(_ uiView: TranscriptContainerView, context: Context) {
        uiView.actions = actions
        let key = "\(theme.name)|\(textScale)|\(contentSize.rawValue)"
        if uiView.styleKey != key {
            uiView.setStyle(TranscriptStyle(theme: theme, textScale: textScale, contentSize: contentSize))
        }
    }

    static func dismantleUIView(_ uiView: TranscriptContainerView, coordinator: ()) {
        uiView.teardown()
    }
}

/**
 * Inverted UITableView transcript.
 *
 * - The table is flipped (scaleY -1) and every cell's contentView flips back,
 *   so the newest row is row 0 and "bottom" is contentOffset == -inset.top:
 *   a session opens at the absolute bottom on the very first layout with no
 *   programmatic scrolling at all, and older pages append at the END of the
 *   table (visually above) without any offset compensation.
 * - Rows are diffed by stable id (UITableViewDiffableDataSource); content
 *   changes use `reconfigureItems` (iOS 15) — cells are never recreated
 *   while streaming.
 * - Attributed bodies and exact row layouts are computed on a background
 *   queue; heights come from that precomputed layout (estimatedRowHeight 0),
 *   so contentSize is always exact.
 * - Auto-follow: pinned while at the bottom; otherwise the first visible
 *   stable row is anchored across updates (no yank, no jump).
 */
final class TranscriptContainerView: UIView, UITableViewDelegate {
    let tableView = UITableView(frame: .zero, style: .plain)
    var actions = TranscriptActions()
    private(set) var styleKey: String

    private let scrollButton = HitExpandedButton(type: .custom)
    private var style: TranscriptStyle
    private var dataSource: UITableViewDiffableDataSource<Int, String>!

    /// Latest items from the view model (oldest → newest).
    private var latestItems: [TranscriptItem] = []
    /// Applied state.
    private var items: [String: TranscriptItem] = [:]
    private var order: [String] = []            // table order: newest first
    private var indexById: [String: Int] = [:]
    private var rows: [String: RowRender] = [:]
    private var expanded = Set<String>()

    private var pendingItems: [TranscriptItem]?
    /// Ids that must be re-rendered regardless of content equality.
    private var forceRender = Set<String>()
    private var renderAll = false
    /// Row whose expand/collapse is pending: anchored on its own bottom edge
    /// (where the tapped footer is) instead of a neighbouring row.
    private var toggleAnchorId: String?
    private var renderTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastWidth: CGFloat = 0
    private var lastNearBottom = true
    /// Explicit "go to bottom" (send / button): keep pinning updates that
    /// land shortly afterwards, even mid-animation.
    private var pinUntil = Date.distantPast
    private static let initialChunk = 40

    init(style: TranscriptStyle) {
        self.style = style
        self.styleKey = style.key
        super.init(frame: .zero)
        backgroundColor = style.background
        configureTable()
        configureScrollButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Setup

    private func configureTable() {
        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
        tableView.backgroundColor = style.background
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.insetsContentViewsToSafeArea = false
        // In table space, top == visual bottom.
        tableView.contentInset = UIEdgeInsets(top: TranscriptMetrics.vPad, left: 0,
                                              bottom: TranscriptMetrics.vPad, right: 0)
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(TranscriptCell.self, forCellReuseIdentifier: TranscriptCell.reuseId)
        tableView.delegate = self
        tableView.accessibilityLabel = "Conversation"
        addSubview(tableView)

        dataSource = UITableViewDiffableDataSource<Int, String>(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: TranscriptCell.reuseId, for: indexPath)
            if let self, let transcriptCell = cell as? TranscriptCell {
                self.configure(transcriptCell, id: id)
            }
            return cell
        }
        dataSource.defaultRowAnimation = .none
    }

    private func configureScrollButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        scrollButton.setImage(UIImage(systemName: "arrow.down", withConfiguration: config), for: .normal)
        scrollButton.layer.cornerRadius = 19
        scrollButton.layer.borderWidth = 0.5
        scrollButton.layer.shadowColor = UIColor.black.cgColor
        scrollButton.layer.shadowOpacity = 0.15
        scrollButton.layer.shadowRadius = 4
        scrollButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        scrollButton.isHidden = true
        scrollButton.accessibilityLabel = "Scroll to latest message"
        scrollButton.addTarget(self, action: #selector(scrollButtonTapped), for: .touchUpInside)
        applyScrollButtonColors()
        addSubview(scrollButton)
    }

    private func applyScrollButtonColors() {
        scrollButton.backgroundColor = style.secondaryBackground.withAlphaComponent(0.95)
        scrollButton.layer.borderColor = style.border.cgColor
        scrollButton.tintColor = style.text
    }

    func bind(transcript: AnyPublisher<[TranscriptItem], Never>,
              scrollRequests: AnyPublisher<Void, Never>) {
        transcript
            .sink { [weak self] items in self?.receive(items) }
            .store(in: &cancellables)
        scrollRequests
            .sink { [weak self] _ in self?.scrollToBottom(animated: true) }
            .store(in: &cancellables)
    }

    func teardown() {
        cancellables.removeAll()
        renderTask?.cancel()
        renderTask = nil
        pendingItems = nil
    }

    func setStyle(_ newStyle: TranscriptStyle) {
        guard newStyle.key != styleKey else { return }
        style = newStyle
        styleKey = newStyle.key
        backgroundColor = newStyle.background
        tableView.backgroundColor = newStyle.background
        applyScrollButtonColors()
        renderAll = true
        receive(latestItems)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        // The table is transformed: drive it with bounds + center, never frame.
        if tableView.bounds.size != size {
            let pinned = isPinnedToBottom
            tableView.bounds = CGRect(origin: tableView.bounds.origin, size: size)
            if pinned { pinToBottom() }
        }
        tableView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        scrollButton.frame = CGRect(x: size.width - 14 - 38, y: size.height - 10 - 38, width: 38, height: 38)
        if size.width > 0, size.width != lastWidth {
            lastWidth = size.width
            if !latestItems.isEmpty {
                renderAll = true
                receive(latestItems)
            }
        }
        if pendingItems != nil { pumpRender() }
    }

    // MARK: Data flow

    private func receive(_ newItems: [TranscriptItem]) {
        // Defensive: diffable data sources trap on duplicate identifiers.
        var seen = Set<String>()
        let unique = newItems.filter { seen.insert($0.id).inserted }
        latestItems = unique
        pendingItems = unique
        pumpRender()
    }

    private func pumpRender() {
        guard renderTask == nil, bounds.width > 0, pendingItems != nil else { return }
        renderTask = Task { @MainActor [weak self] in
            await self?.renderLoop()
        }
    }

    /// Owned, cancellable render loop: renders/measures changed rows off the
    /// main thread, then applies the NEWEST batch (stale batches are skipped).
    private func renderLoop() async {
        defer { renderTask = nil }
        while var batch = pendingItems {
            pendingItems = nil
            if Task.isCancelled { return }
            // First population: render the newest screenful first so the
            // session appears immediately; the rest follows (it lands above
            // the viewport in the inverted table — no visual jump).
            let isInitialChunk = order.isEmpty && batch.count > Self.initialChunk
            if isInitialChunk {
                pendingItems = batch
                batch = Array(batch.suffix(Self.initialChunk))
            }
            let width = currentWidth
            let currentStyle = style
            let jobs = renderJobs(for: batch, width: width)
            var rendered: [String: RowRender] = [:]
            if !jobs.isEmpty {
                let result = await TranscriptRenderQueue.render(
                    TranscriptRenderQueue.Batch(jobs: jobs, width: width, style: currentStyle))
                if Task.isCancelled { return }
                // Style/width changed while rendering: start over.
                guard currentStyle.key == style.key, width == currentWidth else {
                    renderAll = true
                    if pendingItems == nil { pendingItems = latestItems }
                    continue
                }
                rendered = result.results
            }
            // A newer batch arrived while rendering: skip this stale apply
            // (bodies stay in the shared cache, so the next pass is cheap).
            if !isInitialChunk, pendingItems != nil { continue }
            apply(batch, rendered: rendered)
        }
    }

    private var currentWidth: CGFloat {
        tableView.bounds.width > 0 ? tableView.bounds.width : bounds.width
    }

    private func renderJobs(for batch: [TranscriptItem], width: CGFloat) -> [TranscriptRenderer.Job] {
        let all = renderAll
        renderAll = false
        let forced = forceRender
        forceRender.removeAll()
        var jobs: [TranscriptRenderer.Job] = []
        for item in batch {
            let isExpanded = expanded.contains(item.id)
            if !all, !forced.contains(item.id), let existing = rows[item.id], items[item.id] == item,
               existing.layout.width == width {
                continue
            }
            let key = TranscriptRenderer.renderKey(item, expanded: isExpanded, styleKey: style.key)
            if !all, let existing = rows[item.id], existing.renderKey == key, existing.layout.width == width {
                continue
            }
            jobs.append(TranscriptRenderer.Job(id: item.id, item: item, expanded: isExpanded, renderKey: key))
        }
        return jobs
    }

    private func apply(_ batch: [TranscriptItem], rendered: [String: RowRender]) {
        let wasEmpty = order.isEmpty
        let pinned = wasEmpty || Date() < pinUntil || isPinnedToBottom
        let oldIds = Set(order)
        let changedIds = Set(rendered.keys).intersection(oldIds)
            .union(batch.compactMap { item in
                oldIds.contains(item.id) && items[item.id] != item ? item.id : nil
            })
        var anchor: Anchor?
        if let toggled = toggleAnchorId,
           rendered[toggled] != nil || !batch.contains(where: { $0.id == toggled }) {
            toggleAnchorId = nil
            if !pinned { anchor = edgeAnchor(for: toggled) }
        }
        if anchor == nil, !pinned { anchor = captureAnchor(excluding: changedIds) }
        // Rows whose height changed are RELOADED (the table re-queries their
        // height inside the diffable update); content-only changes are
        // reconfigured in place. Never follow `apply` with
        // `performBatchUpdates(nil)` to refresh heights: on iOS 15 that trips
        // UITableView's internal consistency assertion (SIGABRT on "Show all
        // N lines").
        var heightChangedIds = Set<String>()
        for (id, render) in rendered {
            if let old = rows[id], old.layout.height != render.layout.height { heightChangedIds.insert(id) }
            rows[id] = render
        }

        var newItems: [String: TranscriptItem] = [:]
        newItems.reserveCapacity(batch.count)
        for item in batch { newItems[item.id] = item }
        items = newItems
        rows = rows.filter { newItems[$0.key] != nil }
        expanded = expanded.filter { newItems[$0] != nil }
        order = batch.reversed().map(\.id)
        indexById.removeAll(keepingCapacity: true)
        for (i, id) in order.enumerated() { indexById[id] = i }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order, toSection: 0)
        // Only ids present in both the old and new snapshot may be reloaded or
        // reconfigured, and never both at once.
        let reload = order.filter { heightChangedIds.contains($0) && oldIds.contains($0) }
        let reconfigure = order.filter { changedIds.contains($0) && !heightChangedIds.contains($0) }
        if !reload.isEmpty { snapshot.reloadItems(reload) }
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }

        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
        }

        if pinned {
            pinToBottom()
        } else if let anchor {
            restore(anchor)
        }
        updateScrollState()
        if !order.isEmpty, tableView.contentSize.height < tableView.bounds.height {
            actions.loadMore()
        }
    }

    // MARK: Cells

    private func configure(_ cell: TranscriptCell, id: String) {
        guard let item = items[id] else { return }
        let render = rows[id] ?? syncRender(item)
        cell.configure(item: item, render: render, style: style, expanded: expanded.contains(id))
        cell.onAction = { [weak self] in self?.performRowAction(id: id) }
        cell.onSteer = { [weak self] in self?.performSteer(id: id) }
        cell.onToggleExpand = { [weak self] in self?.toggleExpanded(id: id) }
    }

    /// Fallback only (should not happen: rows are rendered before apply).
    private func syncRender(_ item: TranscriptItem) -> RowRender {
        let isExpanded = expanded.contains(item.id)
        let key = TranscriptRenderer.renderKey(item, expanded: isExpanded, styleKey: style.key)
        let render = TranscriptRenderer.run(
            TranscriptRenderer.Job(id: item.id, item: item, expanded: isExpanded, renderKey: key),
            width: tableView.bounds.width, style: style, cache: TranscriptBodyCache.shared)
        rows[item.id] = render
        return render
    }

    private func performRowAction(id: String) {
        guard let item = items[id], let actionId = item.actionId else { return }
        switch item.kind {
        case .queued: actions.cancelQueued(actionId)
        case .offline: actions.discardOffline(actionId)
        default: break
        }
    }

    private func performSteer(id: String) {
        guard let item = items[id], item.kind == .queued, item.canSteer,
              let actionId = item.actionId else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        actions.steerQueued(actionId)
    }

    private func toggleExpanded(id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        forceRender.insert(id)
        toggleAnchorId = id
        receive(latestItems)
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < order.count, let render = rows[order[indexPath.row]] else { return 44 }
        return render.layout.height
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? TranscriptCell)?.updateVisibleSegments()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollState()
        // Tall (segmented) rows materialize only the segments near the viewport.
        for case let cell as TranscriptCell in tableView.visibleCells where cell.isSegmented {
            cell.updateVisibleSegments()
        }
        let visualTopDistance = scrollView.contentSize.height + scrollView.contentInset.bottom
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        if visualTopDistance < 800, !order.isEmpty {
            actions.loadMore()
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < order.count else { return nil }
        let id = order[indexPath.row]
        guard let item = items[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item)
        }
    }

    func tableView(_ tableView: UITableView,
                   previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        targetedPreview(for: configuration)
    }

    func tableView(_ tableView: UITableView,
                   previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        targetedPreview(for: configuration)
    }

    /// Un-flipped preview copy positioned in WINDOW coordinates, so the lift
    /// animation is upright even though the table is inverted.
    private func targetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String,
              let row = indexById[id],
              let window = window,
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? TranscriptCell else {
            return nil
        }
        let rectInWindow = cell.contentView.convert(cell.previewFrame, to: window)
        let preview = cell.makePreviewView()
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: preview.bounds, cornerRadius: cell.previewCornerRadius)
        let target = UIPreviewTarget(container: window,
                                     center: CGPoint(x: rectInWindow.midX, y: rectInWindow.midY))
        return UITargetedPreview(view: preview, parameters: parameters, target: target)
    }

    private func menu(for item: TranscriptItem) -> UIMenu {
        var children: [UIMenuElement] = []
        let text = item.text
        children.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = text
        })
        children.append(UIAction(title: "Select Text", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
            self?.actions.selectText(text)
        })
        if item.kind == .user, let entryId = item.entryId {
            children.append(UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.branch")) { [weak self] _ in
                self?.actions.fork(entryId)
            })
        }
        if let body = rows[item.id]?.body {
            for url in MarkdownRenderer.links(in: body, text: text).prefix(3) {
                let title = "Open " + (url.host ?? url.absoluteString)
                children.append(UIAction(title: title, image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                })
            }
        }
        let diagnostic = "id=\(item.id) kind=\(item.kind.rawValue) entryId=\(item.entryId ?? "nil") "
            + "text=\(String(text.prefix(140)).replacingOccurrences(of: "\n", with: " "))"
        children.append(UIAction(title: "Copy classification", image: UIImage(systemName: "info.circle")) { _ in
            UIPasteboard.general.string = diagnostic
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        })
        return UIMenu(title: "", children: children)
    }

    // MARK: Scrolling

    private var bottomOffsetY: CGFloat { -tableView.contentInset.top }

    private var isPinnedToBottom: Bool {
        tableView.contentOffset.y <= bottomOffsetY + 24 && !tableView.isTracking
    }

    private func pinToBottom() {
        let y = bottomOffsetY
        if abs(tableView.contentOffset.y - y) > 0.5 {
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: y), animated: false)
        }
    }

    private func scrollToBottom(animated: Bool) {
        pinUntil = Date().addingTimeInterval(1.0)
        guard !order.isEmpty else { return }
        tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: bottomOffsetY), animated: animated)
    }

    @objc private func scrollButtonTapped() {
        scrollToBottom(animated: true)
    }

    private struct Anchor {
        let id: String
        let offset: CGFloat
    }

    /// Anchor on a row's VISUAL bottom edge (table-space minY in the inverted
    /// table). Expanding/collapsing grows/shrinks a row upward from that
    /// edge, so the tapped "Show all / Show less" footer stays put.
    private func edgeAnchor(for id: String) -> Anchor? {
        guard let row = indexById[id], tableView.numberOfSections > 0,
              row < tableView.numberOfRows(inSection: 0) else { return nil }
        let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        return Anchor(id: id, offset: rect.minY - tableView.contentOffset.y)
    }

    /// First visible row whose content is NOT changing in this update.
    private func captureAnchor(excluding changed: Set<String>) -> Anchor? {
        guard let visible = tableView.indexPathsForVisibleRows?.sorted() else { return nil }
        for indexPath in visible where indexPath.row < order.count {
            let id = order[indexPath.row]
            if changed.contains(id) { continue }
            let rect = tableView.rectForRow(at: indexPath)
            return Anchor(id: id, offset: rect.minY - tableView.contentOffset.y)
        }
        return nil
    }

    private func restore(_ anchor: Anchor) {
        guard let row = indexById[anchor.id] else { return }
        let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        let minY = bottomOffsetY
        let maxY = max(minY, tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height)
        let y = min(max(rect.minY - anchor.offset, minY), maxY)
        if abs(tableView.contentOffset.y - y) > 0.5 {
            tableView.contentOffset = CGPoint(x: tableView.contentOffset.x, y: y)
        }
    }

    private func updateScrollState() {
        let fromBottom = tableView.contentOffset.y - bottomOffsetY
        let showButton = fromBottom > 200 && !order.isEmpty
        if scrollButton.isHidden == showButton {
            scrollButton.isHidden = !showButton
        }
        let near = fromBottom <= 200
        if near != lastNearBottom {
            lastNearBottom = near
            actions.nearBottomChanged(near)
        }
    }
}
