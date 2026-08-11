import SwiftUI
import UIKit

/// Detects whether the user is actively dragging the enclosing scroll view.
/// The auto-follow uses this to never fight an in-progress pan (the bottom
/// stutter came from the throttled follow jumping mid-gesture).
struct ScrollPanDetector: UIViewRepresentable {
    var onPan: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        DispatchQueue.main.async { context.coordinator.attach() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ScrollPanDetector
        weak var view: UIView?
        private var attached = false

        init(parent: ScrollPanDetector) {
            self.parent = parent
        }

        func attach() {
            guard !attached, let start = view else { return }
            var s: UIView? = start.superview
            while let v = s {
                if let scroll = v as? UIScrollView {
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                    attached = true
                    return
                }
                s = v.superview
            }
        }

        @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
            let active = gesture.state == .began || gesture.state == .changed
            parent.onPan(active)
        }
    }
}
