import SwiftUI
import Combine

/// Publishes the on-screen keyboard height, updated from the keyboard's own
/// will-show/change/hide notifications and animated on the keyboard's exact
/// curve — so a view that follows it moves in lockstep (no settle stutter).
@MainActor
final class KeyboardHeight: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var bag = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillShowNotification))
            .sink { [weak self] n in self?.apply(n, showing: true) }
            .store(in: &bag)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] n in self?.apply(n, showing: false) }
            .store(in: &bag)
    }

    private func apply(_ note: Notification, showing: Bool) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let screenH = UIScreen.main.bounds.height
        let visible = showing ? max(0, screenH - end.minY) : 0
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        // UIKit passes a private curve (7) for keyboard; .easeInOut matches it closely.
        let animation: Animation = curveRaw == UIView.AnimationCurve.linear.rawValue
            ? .linear(duration: duration)
            : .easeInOut(duration: duration)
        withAnimation(animation) { self.height = visible }
    }
}
