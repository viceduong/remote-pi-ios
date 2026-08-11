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
            guard let scrollView = coordinator.findScrollView() else { return }
            func clamp() {
                guard scrollView.contentSize.height > scrollView.bounds.height else { return }
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
            clamp()
            // Single settle pass for lazy content growth — then stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                clamp()
            }
            onClamped()
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
