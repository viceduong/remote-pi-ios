import SwiftUI
import Combine

/// Publishes the on-screen keyboard height, updated from the keyboard's own
/// will-show/hide notifications so views that follow it move on the keyboard's
/// animation timing (no `safeAreaInset` catch-up gap).
@MainActor
final class KeyboardHeight: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var bag = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillShowNotification))
            .sink { [weak self] note in self?.apply(note, showing: true) }
            .store(in: &bag)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] note in self?.apply(note, showing: false) }
            .store(in: &bag)
    }

    private func apply(_ note: Notification, showing: Bool) {
        guard let info = note.userInfo,
              let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let screen = UIScreen.main.bounds.height
        // Height above the bottom edge; 0 when hidden or off-screen.
        let visible = showing ? max(0, screen - frame.minY) : 0
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let animation: Animation = UIView.AnimationCurve(rawValue: Int(curveRaw)) == .linear
            ? .linear(duration: duration) : .easeInOut(duration: duration)
        withAnimation(animation) { self.height = visible }
    }
}
