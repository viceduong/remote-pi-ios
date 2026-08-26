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
        context.coordinator.startConverging(onComplete: onClamped)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: UIView?
        var didClamp = false

        private var observer: NSKeyValueObservation?
        private var lastHeight: CGFloat = 0
        private var stableCount = 0
        private var attempts = 0
        private var timeoutWork: DispatchWorkItem?

        func findScrollView() -> UIScrollView? {
            var s: UIView? = view?.superview
            while let v = s {
                if let sv = v as? UIScrollView { return sv }
                s = v.superview
            }
            return nil
        }

        func startConverging(onComplete: @escaping () -> Void) {
            guard let scrollView = findScrollView() else { return }

            func clamp() {
                guard scrollView.contentSize.height > scrollView.bounds.height else { return }
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
            clamp()

            // Fallback: if content stops changing before KVO (tiny session),
            // latch after the cap/timeout so the trigger never stays armed.
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(onComplete: onComplete)
            }
            timeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)

            // Layout-synchronous convergence: contentSize changes during
            // layout when rows materialize; clamp in that same pass so no
            // intermediate frame is ever displayed.
            observer = scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                guard let self else { return }
                let h = sv.contentSize.height
                if abs(h - self.lastHeight) < 1 { self.stableCount += 1 } else { self.stableCount = 0 }
                self.lastHeight = h
                self.attempts += 1
                sv.setContentOffset(CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
                if self.stableCount >= 2 || self.attempts >= 30 {
                    self.finish(onComplete: onComplete)
                }
            }
        }

        private func finish(onComplete: @escaping () -> Void) {
            guard !didClamp else { return }
            didClamp = true
            timeoutWork?.cancel()
            timeoutWork = nil
            observer?.invalidate()
            observer = nil
            // One final absolute-bottom clamp now that content is stable.
            if let scrollView = findScrollView() {
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), animated: false)
            }
            onComplete()
        }
    }
}
