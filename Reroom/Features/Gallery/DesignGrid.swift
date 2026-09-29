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

    static let columnRange = 1...4

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let layout = GridLayout(columns: columnCount)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = coordinator
        coordinator.attach(to: collectionView, columns: columnCount)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(designs)
        coordinator.syncColumns(columnCount)
    }

    // MARK: - Layout

    /// Flow layout with a column count. 1 column = list with each design's own aspect ratio,
    /// 2–4 columns = edge-to-edge 3:4 grid with hairline gutters.
    final class GridLayout: UICollectionViewFlowLayout {
        let columns: Int

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

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let collectionView else { return }
            switch recognizer.state {
            case .changed:
                if transitionLayout == nil {
                    // Wait for a clear direction before choosing the target layout.
                    guard abs(recognizer.scale - 1) > 0.03 else { return }
                    let target = recognizer.scale > 1 ? currentColumns - 1 : currentColumns + 1
                    guard DesignGrid.columnRange.contains(target) else { return }
                    targetColumns = target
                    transitionLayout = collectionView.startInteractiveTransition(to: GridLayout(columns: target)) { [weak self] completed, _ in
                        self?.transitionEnded(completed: completed)
                    }
                }
                guard let transitionLayout, let target = targetColumns else { return }
                // How far the fingers moved toward the size change between the two layouts.
                let ratio = CGFloat(currentColumns) / CGFloat(target)
                let progress = ratio > 1
                    ? (recognizer.scale - 1) / (ratio - 1)
                    : (1 - recognizer.scale) / (1 - ratio)
                transitionLayout.transitionProgress = min(max(progress, 0), 1)
                transitionLayout.invalidateLayout()

            case .ended:
                guard let transitionLayout else { return }
                let fast = abs(recognizer.velocity) > 1.5
                let movingForward = (targetColumns ?? currentColumns) < currentColumns
                    ? recognizer.velocity > 0
                    : recognizer.velocity < 0
                if transitionLayout.transitionProgress > 0.4 || (fast && movingForward) {
                    collectionView.finishInteractiveTransition()
                } else {
                    collectionView.cancelInteractiveTransition()
                }

            case .cancelled, .failed:
                if transitionLayout != nil { collectionView.cancelInteractiveTransition() }

            default:
                break
            }
        }

        private func transitionEnded(completed: Bool) {
            if completed, let target = targetColumns {
                currentColumns = target
                parent.columnCount = target
                reconfigureVisibleCells()
            }
            transitionLayout = nil
            targetColumns = nil
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
            return CGSize(width: width, height: (width * 4 / 3).rounded())
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
