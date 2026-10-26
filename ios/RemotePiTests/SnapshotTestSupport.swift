import XCTest
import SwiftUI
import UIKit

/// Shared PNG snapshot helpers. Each snapshot is attached to the test run and
/// written to `$SIMULATOR_HOST_HOME/remotepi-snapshots/<name>.png` (uploaded
/// by CI) for visual review — they are not pixel-compared.
@MainActor
extension XCTestCase {
    /// Render a SwiftUI view full-screen (iPhone-sized by default).
    func snapshot<V: View>(_ view: V, name: String,
                           size: CGSize = CGSize(width: 390, height: 844),
                           settle: TimeInterval = 0.6) {
        let controller = UIHostingController(rootView: view)
        snapshot(controller: controller, size: size, name: name, settle: settle)
    }

    func snapshot(controller: UIViewController, size: CGSize, name: String, settle: TimeInterval) {
        // A window must belong to the host app's scene to render (iOS 13+);
        // a scene-less window draws blank.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            let root = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory()
            let dir = URL(fileURLWithPath: root).appendingPathComponent("remotepi-snapshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.isHidden = true
    }
}
