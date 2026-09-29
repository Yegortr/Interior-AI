import SwiftData
import SwiftUI
import UIKit

/// The gallery grid, built the way Photos is: a UICollectionView whose cells host SwiftUI
/// `DesignCard`s, opening a design with UIKit's zoom transition. UIKit asks us for the source
/// cell on every open and close, so the zoom always lands in the right cell — scrolling it
/// into view first if needed — instead of falling back to the centre of the screen.
struct DesignGrid: UIViewControllerRepresentable {
    let designs: [Design]
    let columns: Int
    let generation: GenerationCoordinator
    let modelContext: ModelContext
    let onDelete: (Design) -> Void

    func makeUIViewController(context: Context) -> DesignGridController {
        DesignGridController(generation: generation, modelContext: modelContext)
    }

    func updateUIViewController(_ controller: DesignGridController, context: Context) {
        controller.onDelete = onDelete
        controller.update(designs: designs, columns: columns)
    }
}

final class DesignGridController: UIViewController, UICollectionViewDelegate {
    private let generation: GenerationCoordinator
    private let modelContext: ModelContext
    var onDelete: (Design) -> Void = { _ in }

    private var designs: [UUID: Design] = [:]
    private var order: [UUID] = []
    private var columns = 2
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

    init(generation: GenerationCoordinator, modelContext: ModelContext) {
        self.generation = generation
        self.modelContext = modelContext
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
            guard let self, let design = self.designs[id] else {
                cell.contentConfiguration = nil
                return
            }
            let columns = self.columns
            let generation = self.generation
            cell.contentConfiguration = UIHostingConfiguration {
                DesignCard(design: design, columns: columns)
                    .environment(generation)
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        loadViewIfNeeded()
        // Let the navigation bar's large title collapse as the grid scrolls.
        var ancestor = parent
        while let controller = ancestor {
            controller.setContentScrollView(collectionView)
            ancestor = controller.parent
        }
    }

    // MARK: Data

    func update(designs new: [Design], columns newColumns: Int) {
        loadViewIfNeeded()
        var seen = Set<UUID>()
        let ids = new.map(\.id).filter { seen.insert($0).inserted }
        designs = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let columnsChanged = newColumns != columns
        guard ids != order || columnsChanged else { return }
        let animate = !order.isEmpty && view.window != nil
        order = ids
        columns = newColumns

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        if columnsChanged {
            collectionView.setCollectionViewLayout(makeLayout(), animated: animate)
            snapshot.reconfigureItems(ids)
        }
        dataSource.apply(snapshot, animatingDifferences: animate)
    }

    private func makeLayout() -> UICollectionViewLayout {
        let columns = columns
        return UICollectionViewCompositionalLayout { _, environment in
            if columns >= 2 {
                // Photos-style: edge to edge, hairline gutters, fixed 3:4 cells.
                let spacing: CGFloat = 2
                let width = environment.container.effectiveContentSize.width
                let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(cellWidth / AspectRatio.gridCard.value)),
                    repeatingSubitem: item,
                    count: columns)
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                return section
            } else {
                // One column: each card has its design's own ratio, so cells size themselves.
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(400))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 16
                section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16)
                return section
            }
        }
    }

    // MARK: Opening a design

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        open(id)
    }

    private func open(_ id: UUID) {
        guard presentedViewController == nil, let design = designs[id] else { return }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(
            DesignDetailScreen(design: design) { [weak host] completion in
                guard let host else { return }
                Self.close(host, then: completion)
            }
            .environment(generation)
            .modelContext(modelContext)
        )
        host.modalPresentationStyle = .fullScreen
        host.preferredTransition = .zoom { [weak self] _ in
            self?.sourceCell(for: id)
        }
        present(host, animated: true)
    }

    /// The cell to zoom from / back into, scrolled fully into view first (like Photos).
    private func sourceCell(for id: UUID) -> UIView? {
        guard let indexPath = dataSource.indexPath(for: id) else { return nil }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        if let cell = collectionView.cellForItem(at: indexPath), visibleRect.contains(cell.frame) {
            return cell
        }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        return collectionView.cellForItem(at: indexPath)
    }

    /// Closes the detail screen with the zoom back into its cell. Anything it presents (a sheet,
    /// a confirmation) is let go first, so the zoom itself is never skipped; `completion` runs
    /// once the design is back in the grid.
    private static func close(_ host: UIViewController, then completion: (() -> Void)?) {
        if let presented = host.presentedViewController {
            if presented.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { close(host, then: completion) }
            } else {
                presented.dismiss(animated: true) { close(host, then: completion) }
            }
            return
        }
        host.dismiss(animated: true, completion: completion)
    }

    // MARK: Context menu

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
              let id = dataSource.itemIdentifier(for: indexPaths[0]),
              let design = designs[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSUUID) { [weak self] in
            self?.preview(for: design)
        } actionProvider: { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(
                    title: design.isFavorite ? "Unfavorite" : "Favorite",
                    image: UIImage(systemName: design.isFavorite ? "heart.slash" : "heart")
                ) { _ in design.isFavorite.toggle() },
            ]
            if design.isRetryable {
                actions.append(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { _ in
                    self?.generation.retry(design)
                })
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.onDelete(design)
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: actions), delete])
        }
    }

    /// Tapping the preview opens the design, as in Photos.
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let id = configuration.identifier as? NSUUID else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in self?.open(id as UUID) }
    }

    private func preview(for design: Design) -> UIViewController {
        let ratio = design.aspectRatio.value
        var width = view.bounds.width - 32
        var height = width / ratio
        let maxHeight = view.bounds.height * 0.6
        if height > maxHeight {
            height = maxHeight
            width = height * ratio
        }
        let host = UIHostingController(rootView: DesignCard(design: design, columns: 1).environment(generation))
        host.view.backgroundColor = .clear
        host.preferredContentSize = CGSize(width: width, height: height)
        return host
    }
}

/// The design screen as presented from the grid: its own navigation stack (plants, full
/// screen viewer) with a back button that zooms it back into its cell.
struct DesignDetailScreen: View {
    let design: Design
    let close: (_ completion: (() -> Void)?) -> Void

    var body: some View {
        NavigationStack {
            DesignDetailView(design: design, close: close)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            close(nil)
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                    }
                }
        }
    }
}
