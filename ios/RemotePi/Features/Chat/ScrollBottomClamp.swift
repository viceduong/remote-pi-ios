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
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let scrollView = coordinator.findScrollView() else { return }
            func clamp() {
                guard scrollView.contentSize.height > scrollView.bounds.height else { return false }
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
                return true
            }
            let first = clamp()
            // Settle pass for lazy content growth — then latch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let second = clamp()
                // Latch ONLY on a successful clamp. If content was still
                // loading (empty/too short), keep the trigger armed so the
                // next view update re-runs the clamp — otherwise opening
                // a session with history would burn the one-shot on an empty
                // first pass and open at the top.
                if first || second {
                    coordinator.didClamp = true
                    onClamped()
                }
            }
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
