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
                guard scrollView.contentSize.height > scrollView.bounds.height else { return }
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
            // Converge to the ABSOLUTE bottom. LazyVStack materializes rows in
            // batches, each growing contentSize; a single settle pass lands
            // short on long sessions. Re-clamp while content keeps growing,
            // bounded by BOTH a stability check and a hard cap (2s) so this
            // never becomes a convergence loop.
            var lastHeight: CGFloat = 0
            var stableCount = 0
            var attempts = 0
            func settle() {
                clamp()
                let h = scrollView.contentSize.height
                if abs(h - lastHeight) < 1 { stableCount += 1 } else { stableCount = 0 }
                lastHeight = h
                attempts += 1
                // Stop when the content stops growing twice in a row, or at
                // the hard cap. Latch the one-shot only then.
                if stableCount >= 2 || attempts >= 10 {
                    coordinator.didClamp = true
                    onClamped()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle() }
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
