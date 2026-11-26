import SwiftUI
import UIKit

/// Identifies an attached image to open full-screen.
struct FullImageTarget: Identifiable, Equatable {
    let entryId: String
    let index: Int
    var id: String { "\(entryId)/\(index)" }
}

/// Full-screen, swipeable gallery of the session's attached images. Opens at the
/// tapped image and pages left/right through the rest; each page pinch/double-tap
/// zooms. Falls back to a single image when no gallery list is supplied.
struct FullImageView: View {
    let target: FullImageTarget
    let images: [FullImageTarget]
    let loader: MessageImageLoader
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String

    init(target: FullImageTarget, images: [FullImageTarget], loader: MessageImageLoader) {
        self.target = target
        // Ensure the tapped image is in the list (defensive: empty / stale list).
        self.images = images.contains(target) ? images : [target]
        self.loader = loader
        _selection = State(initialValue: target.id)
    }

    private var currentIndex: Int { images.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(images) { img in
                    ImagePage(target: img, loader: loader).tag(img.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            HStack {
                if images.count > 1 {
                    Text("\(currentIndex + 1) / \(images.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(.leading, 16)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white, .white.opacity(0.25))
                        .padding(12)
                }
                .accessibilityLabel("Close")
            }
            .padding(.top, 4)
        }
    }
}

/// One zoomable page in the gallery; loads its own bytes (cache first).
private struct ImagePage: View {
    let target: FullImageTarget
    let loader: MessageImageLoader
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image).ignoresSafeArea()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Couldn't load image").font(.footnote)
                }
                .foregroundColor(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            if let cached = loader.cachedImage(entryId: target.entryId, index: target.index) {
                image = cached
            } else if let fetched = await loader.image(entryId: target.entryId, index: target.index) {
                image = fetched
            } else {
                failed = true
            }
        }
    }
}

/// UIScrollView-backed pinch/double-tap zoom.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)
        context.coordinator.imageView = iv
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
        }
    }
}
