import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ImageProcessing {
    /// A photo prepared for upload: downscaled, orientation baked in, JPEG encoded.
    struct PreparedImage: Sendable {
        let data: Data
        let pixelSize: CGSize
        var aspectRatio: AspectRatio? { AspectRatio(size: pixelSize) }
    }

    /// Downsamples encoded image data without decoding the full bitmap (fast, low memory).
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pixel size (orientation-corrected) read from the header only.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // EXIF orientations 5–8 are rotated 90°.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func prepareForUpload(data: Data, maxDimension: CGFloat = AppConfig.uploadMaxDimension) -> PreparedImage? {
        guard let image = downsample(data: data, maxPixelSize: maxDimension),
              let jpeg = image.jpegData(compressionQuality: 0.85)
        else { return nil }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return PreparedImage(data: jpeg, pixelSize: size)
    }

    static func prepareForUpload(image: UIImage, maxDimension: CGFloat = AppConfig.uploadMaxDimension) -> PreparedImage? {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        return prepareForUpload(data: data, maxDimension: maxDimension)
    }
}
