import SwiftUI
import UIKit

/// A picked image held in the composer: the downscaled UIImage for the
/// thumbnail strip plus the encoded payload (§17) sent with the prompt.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    let payload: PromptImage

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool { lhs.id == rhs.id }
}

enum ImageEncoder {
    /// Longest-edge cap and JPEG quality. Keeps a single image well under ~1MB
    /// base64 so a prompt with several stays inside the server's 12MB body limit.
    static let maxDimension: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.7

    /// Downscale (preserving aspect), re-encode as JPEG, and wrap as a PromptImage.
    /// Returns nil if the image cannot be encoded.
    static func attachment(from image: UIImage) -> ImageAttachment? {
        let scaled = downscale(image, maxDimension: maxDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        let payload = PromptImage(data: jpeg.base64EncodedString(), mimeType: "image/jpeg")
        return ImageAttachment(image: scaled, payload: payload)
    }

    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let factor = maxDimension / longest
        let target = CGSize(width: floor(size.width * factor), height: floor(size.height * factor))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // target is already in pixels; don't multiply by screen scale
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
