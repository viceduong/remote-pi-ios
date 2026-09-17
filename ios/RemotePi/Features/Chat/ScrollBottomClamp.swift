import SwiftUI

/// Reliable, animation-free initial scroll-to-bottom for lazy stacks.
///
/// `ScrollViewReader.scrollTo(id)` fails silently on unrealized LazyVStack
/// rows. This clamps the underlying UIScrollView's contentOffset to a huge
/// value — UIScrollView snaps to the true bottom and forces lazy
/// instantiation toward it. BOUNDED: one clamp + a single 150ms settle
/// re-clamp, then stops (no convergence loop, no endless scrolling).
struct ScrollBottomClamp: UIViewRepresentable {
    var trigger: Bool
    /// Bump to re-arm the clamp after a wholesale history replacement — the
    /// coordinator's one-shot flag blocks re-runs within the same view.
    var generation: Int = 0
    var onClamped: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.generation != generation {
            // New history epoch: re-arm.
            context.coordinator.generation = generation
            context.coordinator.didClamp = false
        }
        guard trigger, !context.coordinator.didClamp else { return }
        context.coordinator.didClamp = true
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let scrollView = coordinator.findScrollView() else { return }
            func clamp() {
                guard scrollView.contentSize.height > scrollView.bounds.height else { return }
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
            clamp()
            // Event-driven settle: re-clamp whenever contentSize grows (lazy
            // row realization), stop when height is stable at bottom. KVO —
            // zero polling, efficient, and it can never be abandoned
            // mid-layout (the old fixed-attempt loop caused far-off landings).
            var observation: NSKeyValueObservation?
            var stableCount = 0
            var lastHeight: CGFloat = -1
            observation = scrollView.observe(\.contentSize, options: [.new]) { sv, _ in
                let h = sv.contentSize.height
                if abs(h - lastHeight) > 0.5 {
                    lastHeight = h
                    stableCount = 0
                    DispatchQueue.main.async { clamp() }
                } else {
                    stableCount += 1
                    let bottom = sv.contentSize.height - sv.bounds.height
                        + sv.adjustedContentInset.bottom
                    let atBottom = abs(sv.contentOffset.y - max(0, bottom)) < 1
                    if stableCount >= 2, atBottom {
                        observation?.invalidate()
                        context.coordinator.done = true
                        onClamped()
                    }
                }
            }
            // Safety: if nothing happens for 3s and we're at bottom, finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak scrollView] in
                guard let scrollView, !context.coordinator.done else { return }
                let bottom = scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
                if abs(scrollView.contentOffset.y - max(0, bottom)) < 1 {
                    context.coordinator.done = true
                    onClamped()
                }
            }

        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: UIView?
        var didClamp = false
        var generation = 0
        var done = false

        func findScrollView() -> UIScrollView? {
            var s: UIView? = view?.superview
            while let v = s {
                if let sv = v as? UIScrollView { return sv }
                s = v.superview
            }
            return nil
        }
    }
}
