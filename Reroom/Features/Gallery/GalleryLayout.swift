import UIKit

/// The gallery's geometry as plain math (unit-tested; no UIKit isolation).
enum GalleryMetrics {
    enum Mode: Equatable { case grid, list }

    static let gridSpacing: CGFloat = 2
    static let listSpacing: CGFloat = 16
    static let listInset: CGFloat = 16

    /// Grid: two edge-to-edge columns of 3:4 cells, 2 pt gutters (Photos).
    /// List: one column inset 16 pt, each item at its own ratio (width / height), 16 pt apart.
    static func frames(mode: Mode, width: CGFloat, scale: CGFloat, ratios: [CGFloat]) -> [CGRect] {
        guard width > 0 else { return ratios.map { _ in .zero } }
        let pixelScale = max(scale, 1)
        func pixel(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }
        switch mode {
        case .grid:
            let cellWidth = floor((width - gridSpacing) / 2 * pixelScale) / pixelScale
            let cellHeight = pixel(cellWidth / AspectRatio.gridCard.value)
            return ratios.indices.map { index in
                CGRect(x: index % 2 == 0 ? 0 : width - cellWidth,
                       y: CGFloat(index / 2) * (cellHeight + gridSpacing),
                       width: cellWidth, height: cellHeight)
            }
        case .list:
            let cellWidth = width - 2 * listInset
            var y: CGFloat = 0
            var frames: [CGRect] = []
            frames.reserveCapacity(ratios.count)
            for ratio in ratios {
                let height = pixel(cellWidth / max(ratio, 0.1))
                frames.append(CGRect(x: listInset, y: y, width: cellWidth, height: height))
                y += height + listSpacing
            }
            return frames
        }
    }

    static func cellSize(mode: Mode, width: CGFloat, ratio: CGFloat) -> CGSize {
        switch mode {
        case .grid:
            let cellWidth = max(1, (width - gridSpacing) / 2)
            return CGSize(width: cellWidth, height: cellWidth / AspectRatio.gridCard.value)
        case .list:
            let cellWidth = max(1, width - 2 * listInset)
            return CGSize(width: cellWidth, height: cellWidth / max(ratio, 0.1))
        }
    }
}

/// Exact frames for every item (no self-sizing, no estimates): nothing moves unless the data
/// or the width changes. Lookups are a binary search, so scrolling costs nothing here.
final class GalleryLayout: UICollectionViewLayout {
    typealias Mode = GalleryMetrics.Mode

    let mode: Mode
    /// Width / height of an item; only the list uses it (the grid is a fixed 3:4 crop).
    var ratioProvider: (IndexPath) -> CGFloat = { _ in AspectRatio.gridCard.value }
    /// While switching layouts, keep this item at the top of the screen.
    var anchor: IndexPath?

    private var cache: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var insertedItems: Set<IndexPath> = []

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            cache = []
            contentHeight = 0
            return
        }
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        var ratios: [CGFloat] = []
        ratios.reserveCapacity(count)
        for item in 0..<count {
            ratios.append(mode == .list ? ratioProvider(IndexPath(item: item, section: 0)) : AspectRatio.gridCard.value)
        }
        let frames = GalleryMetrics.frames(mode: mode, width: collectionView.bounds.width,
                                           scale: collectionView.traitCollection.displayScale, ratios: ratios)
        var attributes: [UICollectionViewLayoutAttributes] = []
        attributes.reserveCapacity(frames.count)
        for (item, frame) in frames.enumerated() {
            let itemAttributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
            itemAttributes.frame = frame
            attributes.append(itemAttributes)
        }
        cache = attributes
        contentHeight = frames.last?.maxY ?? 0
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // Frames are ordered top to bottom (minY and maxY never decrease).
        var low = 0
        var high = cache.count
        while low < high {
            let middle = (low + high) / 2
            if cache[middle].frame.maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < cache.count, cache[index].frame.minY <= rect.maxY {
            result.append(cache[index])
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cache.indices.contains(indexPath.item) ? cache[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    // New designs grow in at their place; everything else moves (default).
    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        insertedItems = Set(updateItems.compactMap { $0.updateAction == .insert ? $0.indexPathAfterUpdate : nil })
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        insertedItems = []
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard insertedItems.contains(itemIndexPath),
              let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else {
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }
        attributes.alpha = 0
        attributes.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let anchor, let collectionView, let frame = layoutAttributesForItem(at: anchor)?.frame else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        let insets = collectionView.adjustedContentInset
        let maxY = max(-insets.top, contentHeight - collectionView.bounds.height + insets.bottom)
        return CGPoint(x: proposedContentOffset.x, y: min(max(frame.minY - insets.top, -insets.top), maxY))
    }
}
