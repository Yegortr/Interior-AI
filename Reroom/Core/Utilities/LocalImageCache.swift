import SwiftUI
import UIKit

/// Decodes locally stored image data off the main thread at display size and caches the result.
final class LocalImageCache: @unchecked Sendable {
    static let shared = LocalImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func image(key: String, data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        if let hit = cached(key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageProcessing.downsample(data: data, maxPixelSize: maxPixelSize)
        }.value
        guard let decoded else { return nil }
        let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
        cache.setObject(decoded, forKey: key as NSString, cost: cost)
        return decoded
    }
}

/// A design's original or result image, decoded at display size. Size it from the outside.
struct DesignImage: View {
    enum Kind: String { case result, original }

    let design: Design
    var kind: Kind = .result
    var maxPixelSize: CGFloat = 900
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    init(design: Design, kind: Kind = .result, maxPixelSize: CGFloat = 900, contentMode: ContentMode = .fill) {
        self.design = design
        self.kind = kind
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        _image = State(initialValue: LocalImageCache.shared.cached(Self.key(design, kind, maxPixelSize)))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Theme.placeholderGradient)
            }
        }
        .task(id: Self.key(design, kind, maxPixelSize)) { await load() }
    }

    private func load() async {
        let data = kind == .result ? design.resultImageData : design.originalImageData
        guard let data else { return }
        let loaded = await LocalImageCache.shared.image(key: Self.key(design, kind, maxPixelSize), data: data, maxPixelSize: maxPixelSize)
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
    }

    static func key(_ design: Design, _ kind: Kind, _ size: CGFloat) -> String {
        let hasData = (kind == .result ? design.resultImageData : design.originalImageData) != nil
        return "\(design.id)-\(kind.rawValue)-\(Int(size))-\(hasData)"
    }
}
