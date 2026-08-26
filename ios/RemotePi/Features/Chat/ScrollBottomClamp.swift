import SwiftUI
import UIKit

/// Reliable, animation-free initial scroll-to-bottom for lazy stacks.
///
/// `ScrollViewReader.scrollTo(id)` fails silently on unrealized LazyVStack
/// rows. This clamps the underlying UIScrollView's contentOffset to a huge
/// value — UIScrollView snaps to the true bottom and forces lazy
/// instantiation toward it.
///
/// SMOOTHNESS: re-clamping on a timer paints intermediate short positions
/// (jitter). Instead we observe `contentSize` — which changes synchronously
/// DURING layout when LazyVStack materializes rows — and clamp in the same
/// layout pass, BEFORE the next frame renders. The user only ever sees the
/// bottom position: one motion, no jitter. Bounded by a stability check,
/// an attempt cap, and a hard timeout, so it can never loop forever.
struct ScrollBottomClamp: UIViewRepresentable {
    var trigger: Bool
    /// When true, keep pinning to the bottom while content grows (async
    /// images, streamed rows). Parent drives this from its nearBottom state,
    /// so we only ever move the viewport at the bottom edge — where the user
    /// is looking — never yanking from mid-scroll.
    var follow: Bool = false
    var onClamped: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        if !coordinator.didClamp, trigger {
            coordinator.startSettle(onComplete: onClamped)
        } else if coordinator.didClamp, follow {
            // Pin-to-bottom while the user stays at the bottom: contentSize
            // changes (image arrivals, appended rows) re-clamp immediately —
            // content grows AT the viewport, so this is a single smooth
            // motion, not a jump.
            coordinator.pinIfAtBottom()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: UIView?
        var didClamp = false

        // Late-growth pin: async images and streamed rows change contentSize
        // AFTER the open clamp latched. SwiftUI updates don't fire for those,
        // so pinIfAtBottom() alone misses them. This observer re-clamps at
        // the UIKit level, but ONLY while the user is at the bottom.
        private var growthObserver: NSKeyValueObservation?

        func findScrollView() -> UIScrollView? {
            var s: UIView? = view?.superview
            while let v = s {
                if let sv = v as? UIScrollView { return sv }
                s = v.superview
            }
            return nil
        }

        private func clamp() {
            guard let scrollView = findScrollView() else { return }
            guard scrollView.contentSize.height > scrollView.bounds.height else { return }
            scrollView.setContentOffset(
                CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
        }

        /// Initial open: immediate clamp + one settle pass, then latch.
        /// No observers, no timeouts — nothing to force full-stack
        /// materialization or race a blank screen.
        func startSettle(onComplete: @escaping () -> Void) {
            guard !didClamp else { return }
            clamp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !self.didClamp else { return }
                let sv = self.findScrollView()
                let grew = (sv?.contentSize.height ?? 0) > (self.lastSettledHeight > 0 ? self.lastSettledHeight : 0)
                self.clamp()
                self.lastSettledHeight = sv?.contentSize.height ?? 0
                // Latch only when content is tall enough to clamp; if it was
                // still empty/loading, stay armed for the next view update.
                if (sv?.contentSize.height ?? 0) > (sv?.bounds.height ?? 0) {
                    self.didClamp = true
                    self.installGrowthPin()
                    onComplete()
                } else if grew {
                    // Content is growing but still short — retry once more.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, !self.didClamp else { return }
                        self.clamp()
                        if (self.findScrollView()?.contentSize.height ?? 0) > (self.findScrollView()?.bounds.height ?? 0) {
                            self.didClamp = true
                            self.installGrowthPin()
                            onComplete()
                        }
                    }
                }
            }
        }

        private var lastSettledHeight: CGFloat = 0

        /// Observe contentSize growth after the open clamp latched. Async
        /// images and streamed rows grow the stack without any SwiftUI update,
        /// so pin here at the UIKit level — but only when the user is at the
        /// bottom (within threshold of max offset). Scrolling up disables the
        /// pin automatically; scrolling back near the bottom re-arms it.
        func installGrowthPin() {
            guard growthObserver == nil, let scrollView = findScrollView() else { return }
            growthObserver = scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                guard let self, self.didClamp else { return }
                let maxOffset = sv.contentSize.height - sv.bounds.height
                guard maxOffset > 0 else { return }
                guard sv.contentOffset.y >= maxOffset - 80 else { return }
                sv.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
        }

        func pinIfAtBottom() {
            guard let scrollView = findScrollView() else { return }
            // Only act when the user is visually at the bottom (offset near
            // the max) — the parent only calls this while nearBottom anyway,
            // but double-check to stay safe against stale state.
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            guard maxOffset > 0, scrollView.contentOffset.y >= maxOffset - 40 else { return }
            clamp()
        }
    }
}
