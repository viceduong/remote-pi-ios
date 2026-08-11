import SwiftUI

/// Deterministic, animation-free scroll-to-bottom for lazy stacks.
///
/// `ScrollViewReader.scrollTo(id)` fails silently while `LazyVStack` hasn't
/// instantiated the target row — causing the initial stutter/jitter when
/// opening a session. Instead this clamps the underlying UIScrollView's
/// contentOffset to a huge value; UIScrollView snaps to the true bottom and
/// forces lazy instantiation toward it. Re-clamps a few times until the
/// content size converges (50ms apart, all non-animated — no visible jump).
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
            var attempts = 0
            func clamp() {
                guard attempts < 5 else { return }
                attempts += 1
                let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
                guard maxOffset > 0 else {
                    // Content not laid out yet — retry shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { clamp() }
                    return
                }
                scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Converge: lazy stacks grow their content size as rows
                    // instantiate — re-clamp until stable.
                    if abs(scrollView.contentOffset.y - max(0, scrollView.contentSize.height - scrollView.bounds.height)) > 2 {
                        clamp()
                    }
                }
            }
            clamp()
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
