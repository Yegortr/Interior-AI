import SwiftData
import UIKit

enum DesignImageKind: String {
    case result, original
}

/// One decoded size of one of a design's two pictures. Keys never read the image blobs: an
/// original never changes and a result is written once, so `id + kind + size` is stable.
struct DesignImageRequest: Hashable {
    let designID: UUID
    let kind: DesignImageKind
    /// Long edge in pixels, rounded up to a multiple of 64 so nearby sizes share one decode.
    let maxPixelSize: Int

    init(designID: UUID, kind: DesignImageKind, maxPixelSize: CGFloat) {
        self.designID = designID
        self.kind = kind
        let pixels = maxPixelSize.isFinite ? max(64, maxPixelSize) : 64
        self.maxPixelSize = Int((pixels / 64).rounded(.up)) * 64
    }

    var key: String { "\(designID.uuidString)-\(kind.rawValue)-\(maxPixelSize)" }
    fileprivate var family: String { DesignImagePipeline.family(designID, kind) }
    /// Viewer-size decodes: their own memory budget, never written to disk.
    var isFullSize: Bool { maxPixelSize > 2048 }

    /// The decode size for an image of `imageAspect` (width / height) to aspect-fill `size` points.
    static func aspectFill(designID: UUID, kind: DesignImageKind, size: CGSize, scale: CGFloat, imageAspect: CGFloat) -> DesignImageRequest {
        let pixelScale = scale > 0 ? scale : 3
        let width = max(1, size.width * pixelScale)
        let height = max(1, size.height * pixelScale)
        let aspect = max(imageAspect, 0.05)
        let drawnHeight = max(width / aspect, height)          // drawn at aspect·drawnHeight × drawnHeight
        return DesignImageRequest(designID: designID, kind: kind, maxPixelSize: max(aspect * drawnHeight, drawnHeight))
    }
}

/// Decodes design pictures off the main thread, at the size they're shown, once.
///
/// memory (NSCache) → disk (small JPEGs in Caches) → the SwiftData blob, read through a
/// background ModelContext (a result that isn't saved yet comes from the main context's unsaved
/// changes — never a disk read on the main thread). Requests for one key share one decode; a
/// decode nobody waits for is cancelled before it starts. Every decode also yields the picture's
/// average colour, used as its placeholder so a rare miss never shows a light box.
/// Bookkeeping (`jobs`, `families`, `averageColors`, `tokenCounter`) is touched on the main thread only.
final class DesignImagePipeline: @unchecked Sendable {
    static let shared = DesignImagePipeline()

    struct Token {
        fileprivate let key: String
        fileprivate let number: Int
    }

    private final class Job {
        let operation: Operation
        var handlers: [Int: (UIImage?) -> Void] = [:]
        init(operation: Operation) { self.operation = operation }
    }

    private struct Decoded {
        let image: UIImage
        let averageColor: UIColor?
    }

    private let thumbnails = NSCache<NSString, UIImage>()
    private let fullSize = NSCache<NSString, UIImage>()
    private let queue = OperationQueue()
    private let directory: URL
    private var container: ModelContainer?
    private var mainContext: ModelContext?
    private var jobs: [String: Job] = [:]
    private var families: [String: Set<Int>] = [:]
    private var averageColors: [String: UIColor] = [:]
    private var tokenCounter = 0

    private init() {
        // Grid thumbnails and viewer-size images never compete for one budget.
        thumbnails.totalCostLimit = 160 * 1024 * 1024
        fullSize.totalCostLimit = 96 * 1024 * 1024
        queue.name = "DesignImagePipeline"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("DesignThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    fileprivate static func family(_ designID: UUID, _ kind: DesignImageKind) -> String {
        "\(designID.uuidString)-\(kind.rawValue)"
    }

    /// Call once, on the main thread, before the first load.
    func configure(container: ModelContainer, mainContext: ModelContext) {
        self.container = container
        self.mainContext = mainContext
    }

    // MARK: Memory

    func cachedImage(_ request: DesignImageRequest) -> UIImage? {
        cache(for: request).object(forKey: request.key as NSString)
    }

    /// The largest size of this picture already in memory — an instant placeholder.
    func bestCachedImage(designID: UUID, kind: DesignImageKind) -> UIImage? {
        for size in (families[Self.family(designID, kind)] ?? []).sorted(by: >) {
            let request = DesignImageRequest(designID: designID, kind: kind, maxPixelSize: CGFloat(size))
            if let image = cachedImage(request) { return image }
        }
        return nil
    }

    /// The picture's average colour, once any size of it has been decoded.
    func averageColor(designID: UUID, kind: DesignImageKind) -> UIColor? {
        averageColors[Self.family(designID, kind)]
    }

    // MARK: Loading (main thread)

    /// `completion` runs on the main thread — synchronously on a memory hit (then no token is
    /// returned). `nil` means the picture couldn't be produced.
    @discardableResult
    func load(_ request: DesignImageRequest, priority: Operation.QueuePriority = .normal, completion: @escaping (UIImage?) -> Void) -> Token? {
        if let hit = cachedImage(request) {
            completion(hit)
            return nil
        }
        tokenCounter += 1
        let token = Token(key: request.key, number: tokenCounter)
        if let job = jobs[request.key] {
            job.handlers[token.number] = completion
            if priority.rawValue > job.operation.queuePriority.rawValue {
                job.operation.queuePriority = priority
            }
            return token
        }
        let operation = makeOperation(for: request)
        operation.queuePriority = priority
        let job = Job(operation: operation)
        job.handlers[token.number] = completion
        jobs[request.key] = job
        queue.addOperation(operation)
        return token
    }

    func cancel(_ token: Token?) {
        guard let token, let job = jobs[token.key] else { return }
        job.handlers[token.number] = nil
        guard job.handlers.isEmpty, !job.operation.isExecuting else { return }
        job.operation.cancel()
        jobs[token.key] = nil
    }

    /// Designs that are gone: drop what's known about them and their disk thumbnails.
    func forget(designIDs: Set<UUID>) {
        guard !designIDs.isEmpty else { return }
        let prefixes = designIDs.map(\.uuidString)
        for id in designIDs {
            for kind in [DesignImageKind.result, .original] {
                families[Self.family(id, kind)] = nil
                averageColors[Self.family(id, kind)] = nil
            }
        }
        let directory = self.directory
        queue.addOperation {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: Work

    private func makeOperation(for request: DesignImageRequest) -> Operation {
        let operation = BlockOperation()
        let fileURL = request.isFullSize ? nil : directory.appendingPathComponent(request.key + ".jpg")
        let container = self.container
        let pipeline = self
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let decoded = DesignImagePipeline.produce(
                request, fileURL: fileURL, container: container,
                isCancelled: { operation.isCancelled },
                unsavedBlob: { pipeline.unsavedBlobOnMain(request) }
            )
            DispatchQueue.main.async {
                pipeline.finish(request, operation: operation, decoded: decoded)
            }
        }
        return operation
    }

    private static func produce(
        _ request: DesignImageRequest, fileURL: URL?, container: ModelContainer?,
        isCancelled: () -> Bool, unsavedBlob: () -> Data?
    ) -> Decoded? {
        let pixels = CGFloat(request.maxPixelSize)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let image = ImageProcessing.downsample(data: data, maxPixelSize: pixels) {
            return Decoded(image: image, averageColor: averageColor(of: image))
        }
        if isCancelled() { return nil }
        var blob: Data?
        if let container {
            blob = readBlob(in: ModelContext(container), designID: request.designID, kind: request.kind)
        }
        if blob == nil { blob = unsavedBlob() }
        // Saved between the two reads (the main context had no changes left): it's on disk now.
        if blob == nil, let container, !isCancelled() {
            blob = readBlob(in: ModelContext(container), designID: request.designID, kind: request.kind)
        }
        guard let blob, !isCancelled(),
              let image = ImageProcessing.downsample(data: blob, maxPixelSize: pixels) else { return nil }
        if let fileURL, let jpeg = image.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: fileURL, options: .atomic)
        }
        return Decoded(image: image, averageColor: averageColor(of: image))
    }

    private static func readBlob(in context: ModelContext, designID: UUID, kind: DesignImageKind) -> Data? {
        var descriptor = FetchDescriptor<Design>(predicate: #Predicate<Design> { $0.id == designID })
        descriptor.fetchLimit = 1
        guard let design = try? context.fetch(descriptor).first else { return nil }
        return kind == .result ? design.resultImageData : design.originalImageData
    }

    /// A result that just arrived may not be saved yet, so the background context can't see it.
    /// Only the main context's unsaved models are looked at: that data is already in memory.
    private func unsavedBlobOnMain(_ request: DesignImageRequest) -> Data? {
        let read = { () -> Data? in
            guard let context = self.mainContext, context.hasChanges else { return nil }
            let models = context.insertedModelsArray + context.changedModelsArray
            for case let design as Design in models where design.id == request.designID && !design.isDeleted {
                return request.kind == .result ? design.resultImageData : design.originalImageData
            }
            return nil
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    /// Mean colour of a 4×4 downsample.
    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage,
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let pixels = context.data else { return nil }
        var sums = [0, 0, 0]
        for y in 0..<4 {
            for x in 0..<4 {
                let offset = y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    sums[channel] += Int(pixels.load(fromByteOffset: offset + channel, as: UInt8.self))
                }
            }
        }
        return UIColor(red: CGFloat(sums[0]) / 4080, green: CGFloat(sums[1]) / 4080, blue: CGFloat(sums[2]) / 4080, alpha: 1)
    }

    private func finish(_ request: DesignImageRequest, operation: Operation, decoded: Decoded?) {
        if let decoded {
            let cost = decoded.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            cache(for: request).setObject(decoded.image, forKey: request.key as NSString, cost: cost)
            families[request.family, default: []].insert(request.maxPixelSize)
            if let color = decoded.averageColor { averageColors[request.family] = color }
        }
        guard let job = jobs[request.key] else { return }
        // A newer job for the same key (this one was cancelled mid-flight) keeps running on failure.
        guard decoded != nil || job.operation === operation else { return }
        jobs[request.key] = nil
        if job.operation !== operation { job.operation.cancel() }
        for handler in job.handlers.values { handler(decoded?.image) }
    }

    private func cache(for request: DesignImageRequest) -> NSCache<NSString, UIImage> {
        request.isFullSize ? fullSize : thumbnails
    }
}
