import SwiftUI
import UIKit

/// The home grid, built like Photos: a `UICollectionView` whose pinch gesture drives a native
/// *interactive layout transition* (`startInteractiveTransition(to:)`). UIKit interpolates every
/// cell's frame each frame and finishes or cancels the transition when the fingers lift — no
/// custom scaling. Cells are SwiftUI (`UIHostingConfiguration`), menus are native UIKit menus.
struct DesignGrid: UIViewRepresentable {
    let designs: [Design]
    @Binding var columnCount: Int
    let coordinatorEnvironment: GenerationCoordinator
    let zoomNamespace: Namespace.ID
    let onSelect: (Design) -> Void
    let onDelete: (Design) -> Void

    /// Zoom levels, as in Photos: one-up (aspect), 3 and 5 square columns.
    static let levels = [1, 3, 5]

    static func nearestLevel(_ columns: Int) -> Int {
        levels.min { abs($0 - columns) < abs($1 - columns) } ?? 3
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let layout = GridLayout(columns: DesignGrid.nearestLevel(columnCount))
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = coordinator
        coordinator.attach(to: collectionView, columns: DesignGrid.nearestLevel(columnCount))
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(designs)
        coordinator.syncColumns(DesignGrid.nearestLevel(columnCount))
    }

    // MARK: - Layout

    /// Flow layout with a column count. 1 column = one-up with each design's own aspect ratio,
    /// 3/5 columns = edge-to-edge square grid with hairline gutters (like Photos).
    final class GridLayout: UICollectionViewFlowLayout {
        let columns: Int

        /// The item under the fingers during a pinch and where it should stay on screen.
        struct Anchor {
            let indexPath: IndexPath
            /// Point inside the item, 0…1.
            let unit: CGPoint
            /// Finger position in the collection view's visible area.
            let screen: CGPoint
        }

        var anchor: Anchor?

        init(columns: Int) {
            self.columns = columns
            super.init()
            let isList = columns == 1
            minimumInteritemSpacing = isList ? 16 : 2
            minimumLineSpacing = isList ? 16 : 2
            sectionInset = isList
                ? UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
                : UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            newBounds.width != collectionView?.bounds.width
        }

        /// UIKit asks the destination layout for the final offset when a (interactive) layout
        /// transition finishes: keep the anchored item under the fingers, like Photos.
        override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
            guard let anchor, let collectionView,
                  let frame = layoutAttributesForItem(at: anchor.indexPath)?.frame else {
                return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
            }
            let y = frame.minY + anchor.unit.y * frame.height - anchor.screen.y
            return CGPoint(x: proposedContentOffset.x, y: GridLayout.clampedOffsetY(y, contentHeight: collectionViewContentSize.height, in: collectionView))
        }

        static func clampedOffsetY(_ y: CGFloat, contentHeight: CGFloat, in collectionView: UICollectionView) -> CGFloat {
            let insets = collectionView.adjustedContentInset
            let minY = -insets.top
            let maxY = max(minY, contentHeight - collectionView.bounds.height + insets.bottom)
            return min(max(y, minY), maxY)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
        var parent: DesignGrid

        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var designsByID: [UUID: Design] = [:]
        private var orderedIDs: [UUID] = []
        private(set) var currentColumns = 2

        // Interactive pinch transition state.
        private var transitionLayout: UICollectionViewTransitionLayout?
        private var targetColumns: Int?

        init(parent: DesignGrid) {
            self.parent = parent
        }

        func attach(to collectionView: UICollectionView, columns: Int) {
            self.collectionView = collectionView
            currentColumns = columns

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
                guard let self, let design = self.designsByID[id] else { return }
                let columns = self.currentColumns
                cell.contentConfiguration = UIHostingConfiguration {
                    DesignCard(design: design, columns: columns)
                        .matchedTransitionSource(id: design.id, in: self.parent.zoomNamespace)
                        .environment(self.parent.coordinatorEnvironment)
                }
                .margins(.all, 0)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)
        }

        func apply(_ designs: [Design]) {
            designsByID = Dictionary(designs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ids = designs.map(\.id)
            guard ids != orderedIDs else { return }
            let animate = !orderedIDs.isEmpty
            orderedIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: animate)
        }

        /// Column changes coming from SwiftUI (the View As menu).
        func syncColumns(_ columns: Int) {
            guard transitionLayout == nil, columns != currentColumns, let collectionView else { return }
            currentColumns = columns
            collectionView.setCollectionViewLayout(GridLayout(columns: columns), animated: true)
            reconfigureVisibleCells()
        }

        private func reconfigureVisibleCells() {
            guard var snapshot = dataSource?.snapshot(), !snapshot.itemIdentifiers.isEmpty else { return }
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        // MARK: Pinch → interactive layout transition

        /// Scale at which the current level started (a single pinch can walk several levels).
        private var scaleBase: CGFloat = 1
        private var isFinishing = false
        private var anchor: GridLayout.Anchor?

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let collectionView else { return }
            switch recognizer.state {
            case .began:
                scaleBase = 1

            case .changed:
                guard !isFinishing else { return }
                let scale = recognizer.scale / scaleBase

                if transitionLayout == nil {
                    // Wait for a clear direction before choosing the next level.
                    guard abs(scale - 1) > 0.03,
                          let index = DesignGrid.levels.firstIndex(of: currentColumns) else { return }
                    let nextIndex = scale > 1 ? index - 1 : index + 1
                    guard DesignGrid.levels.indices.contains(nextIndex) else { return }
                    let target = DesignGrid.levels[nextIndex]
                    anchor = makeAnchor(for: recognizer, in: collectionView)
                    (collectionView.collectionViewLayout as? GridLayout)?.anchor = anchor
                    let destination = GridLayout(columns: target)
                    destination.anchor = anchor
                    targetColumns = target
                    transitionLayout = collectionView.startInteractiveTransition(to: destination) { [weak self] completed, _ in
                        self?.transitionEnded(completed: completed)
                    }
                }
                guard let transitionLayout, let target = targetColumns else { return }

                // Progress = how far the fingers moved toward the size change between levels.
                let ratio = CGFloat(currentColumns) / CGFloat(target)
                let progress = ratio > 1 ? (scale - 1) / (ratio - 1) : (1 - scale) / (1 - ratio)
                transitionLayout.transitionProgress = min(max(progress, 0), 1)
                transitionLayout.invalidateLayout()
                keepAnchorUnderFingers(recognizer, transitionLayout: transitionLayout, in: collectionView)

                // Reached the next level mid-gesture: commit it and keep going (Photos walks levels).
                if progress >= 1 {
                    isFinishing = true
                    scaleBase = recognizer.scale
                    collectionView.finishInteractiveTransition()
                }

            case .ended:
                guard let transitionLayout, !isFinishing else { return }
                let towardTarget = (targetColumns ?? currentColumns) < currentColumns
                    ? recognizer.velocity > 0
                    : recognizer.velocity < 0
                if transitionLayout.transitionProgress > 0.35 || (abs(recognizer.velocity) > 1.2 && towardTarget) {
                    isFinishing = true
                    collectionView.finishInteractiveTransition()
                } else {
                    isFinishing = true
                    collectionView.cancelInteractiveTransition()
                }

            case .cancelled, .failed:
                if transitionLayout != nil, !isFinishing {
                    isFinishing = true
                    collectionView.cancelInteractiveTransition()
                }

            default:
                break
            }
        }

        private func makeAnchor(for recognizer: UIPinchGestureRecognizer, in collectionView: UICollectionView) -> GridLayout.Anchor? {
            let location = recognizer.location(in: collectionView)   // content coordinates
            let indexPath = collectionView.indexPathForItem(at: location)
                ?? collectionView.indexPathsForVisibleItems.min { lhs, rhs in
                    let l = collectionView.layoutAttributesForItem(at: lhs)?.center ?? .zero
                    let r = collectionView.layoutAttributesForItem(at: rhs)?.center ?? .zero
                    return hypot(l.x - location.x, l.y - location.y) < hypot(r.x - location.x, r.y - location.y)
                }
            guard let indexPath, let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.width > 0, frame.height > 0 else { return nil }
            let unit = CGPoint(
                x: min(max((location.x - frame.minX) / frame.width, 0), 1),
                y: min(max((location.y - frame.minY) / frame.height, 0), 1)
            )
            let screen = CGPoint(x: location.x - collectionView.contentOffset.x, y: location.y - collectionView.contentOffset.y)
            return GridLayout.Anchor(indexPath: indexPath, unit: unit, screen: screen)
        }

        /// While pinching, scroll so the item that was under the fingers stays under them.
        private func keepAnchorUnderFingers(_ recognizer: UIPinchGestureRecognizer, transitionLayout: UICollectionViewTransitionLayout, in collectionView: UICollectionView) {
            guard let anchor, let frame = transitionLayout.layoutAttributesForItem(at: anchor.indexPath)?.frame else { return }
            let location = recognizer.location(in: collectionView)
            let screenY = location.y - collectionView.contentOffset.y
            let y = frame.minY + anchor.unit.y * frame.height - screenY
            let clamped = GridLayout.clampedOffsetY(y, contentHeight: transitionLayout.collectionViewContentSize.height, in: collectionView)
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clamped)
        }

        // MARK: Sizing

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let columns = (collectionViewLayout as? GridLayout)?.columns ?? currentColumns
            let flow = collectionViewLayout as? UICollectionViewFlowLayout
            let insets = (flow?.sectionInset.left ?? 0) + (flow?.sectionInset.right ?? 0)
            let available = collectionView.bounds.width - insets
            guard available > 0 else { return CGSize(width: 1, height: 1) }

            if columns == 1 {
                let ratio = dataSource.itemIdentifier(for: indexPath).flatMap { designsByID[$0] }?.aspectRatio.value ?? 0.75
                return CGSize(width: available, height: (available / max(ratio, 0.1)).rounded())
            }
            let spacing = CGFloat(columns - 1) * 2
            let width = ((available - spacing) / CGFloat(columns)).rounded(.down)
            return CGSize(width: width, height: width)
        }

        // MARK: Selection & menus

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard transitionLayout == nil,
                  let id = dataSource.itemIdentifier(for: indexPath), let design = designsByID[id] else { return }
            parent.onSelect(design)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first,
                  let id = dataSource.itemIdentifier(for: indexPath), let design = designsByID[id] else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                var actions: [UIMenuElement] = [
                    UIAction(
                        title: design.isFavorite ? "Unfavorite" : "Favorite",
                        image: UIImage(systemName: design.isFavorite ? "heart.slash" : "heart")
                    ) { _ in design.isFavorite.toggle() },
                ]
                if design.isRetryable {
                    actions.append(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        self?.parent.coordinatorEnvironment.retry(design)
                    })
                }
                let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.parent.onDelete(design)
                }
                return UIMenu(children: [UIMenu(options: .displayInline, children: actions), delete])
            }
        }
    }
}
