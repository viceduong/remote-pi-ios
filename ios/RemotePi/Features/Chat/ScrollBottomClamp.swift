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
    var onClamped: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard trigger, !context.coordinator.didClamp else { return }
        context.coordinator.didClamp = true
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let scrollView = coordinator.findScrollView() else {
                // No scroll view found — fail OPEN. Never leave the session
                // dimmed/disabled forever (looked like a blank session).
                onClamped()
                return
            }
            // Safety timeout: even if lazy content keeps growing, undim after
            // 4s so the session can never get stuck behind the loading cover.
            let safety = DispatchWorkItem { onClamped() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: safety)
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
            var attempts = 0
            func settle() {
                clamp()
                attempts += 1
                if settled() || attempts >= 12 {
                    safety.cancel()
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
