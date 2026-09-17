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
            // Settle passes for lazy content growth — keep re-clamping until
            // the scroll view is genuinely at the bottom, then signal ready.
            // (A fixed 150ms was too early: content kept growing and the user
            // saw the view still scrolling after the dim lifted.)
            func settled() -> Bool {
                let bottom = scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
                return abs(scrollView.contentOffset.y - max(0, bottom)) < 1
            }
            // Absolute-bottom guarantee: re-clamp until the offset is stable
            // at the bottom across TWO consecutive passes (content height must
            // stop growing). Heavy sessions keep realizing lazy rows for
            // seconds — a fixed attempt count landed mid-content. Bounded at
            // 40 passes (~4s) with a safety fallback.
            var attempts = 0
            var lastHeight: CGFloat = -1
            var stablePasses = 0
            func settle() {
                clamp()
                attempts += 1
                let h = scrollView.contentSize.height
                if settled() && abs(h - lastHeight) < 0.5 {
                    stablePasses += 1
                    if stablePasses >= 2 {
                        onClamped()
                        return
                    }
                } else {
                    stablePasses = 0
                }
                lastHeight = h
                if attempts >= 80 {
                    onClamped()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle() }
            }
            settle()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: UIView?
        var didClamp = false
        var generation = 0

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
