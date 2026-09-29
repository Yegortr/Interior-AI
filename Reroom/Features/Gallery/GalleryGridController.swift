import Observation
import SwiftData
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum GalleryFilter: String, CaseIterable {
    case all = "All Designs", rooms = "Rooms", gardens = "Gardens", favorites = "Favorites"

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .rooms: "sofa"
        case .gardens: "leaf"
        case .favorites: "heart"
        }
    }

    var title: String { self == .all ? "Reroom" : rawValue }

    func includes(_ content: DesignTileContent) -> Bool {
        switch self {
        case .all: true
        case .rooms: !content.isGarden
        case .gardens: content.isGarden
        case .favorites: content.isFavorite
        }
    }
}

/// The home grid, built like Photos: a UICollectionView with UIKit cells.
///
/// Rules that keep the zoom and taps exact:
/// - items are `Design.id`s; a tap opens the design that was drawn under the finger;
/// - the displayed order never changes while a design is pushed or a navigation transition runs,
///   while a finger is on the grid or it is scrolling, or while a context menu is up. Changes wait
///   and are applied once the grid is settled (`settle()` after the pop has fully finished);
/// - changes above the visible area keep what's on screen in place (no animation);
/// - status / favourite changes reconfigure cells in place (they never move a cell).
final class GalleryGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private struct ScrollAnchor {
        let id: UUID
        /// The item's top relative to the content offset.
        let offset: CGFloat
    }

    private weak var router: GalleryRouter?

    private var collectionView: UICollectionView!
    private var layout: GalleryLayout!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private let touchRecorder = TouchDownRecorder(target: nil, action: nil)

    // Model side: the latest state of every design.
    private var orderedIDs: [UUID] = []
    private var designsByID: [UUID: Design] = [:]
    private var contents: [UUID: DesignTileContent] = [:]
    private var tracked: [UUID: ObjectIdentifier] = [:]

    // Display side: what the collection view shows.
    private var shownIDs: [UUID] = []
    private var shownContents: [UUID: DesignTileContent] = [:]
    private var layoutRatios: [UUID: CGFloat] = [:]
    private var hasData = false             // setDesigns has run (don't show "empty" before the first @Query result)
    private var hasApplied = false
    private var needsApply = false
    private var isContextMenuActive = false
    private var deleteAfterMenu: UUID?
    private var refreshScheduled = false
    private var retryScheduled = false
    private var isWaitingForTransition = false
    /// What screens closed with `GalleryRouter.close` wait to run, tagged with the screen.
    private var afterReturn: [(owner: ObjectIdentifier, action: () -> Void)] = []

    // Taps while cells move: resolved from what is drawn, opened once they stop.
    private var reflows = 0
    private var reflowStart: CFTimeInterval = 0
    private var tapDuringReflow = false
    private var drawnTapID: UUID?
    private var queuedOpenID: UUID?

    private var filter: GalleryFilter = .all
    private var mode: GalleryMetrics.Mode
    private var optionsSymbol: String?
    private var prefetchTokens: [String: DesignImagePipeline.Token] = [:]
    private var timer: Timer?
    /// The long-press preview's tile: its elapsed time ticks with the cells'.
    private weak var previewTile: DesignTileView?

    private let optionsItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: nil)
    private let addItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "plus"), primaryAction: nil, menu: nil)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private static let columnsKey = "gallery.columnCount"   // same key as the old @AppStorage

    init(router: GalleryRouter) {
        self.router = router
        self.mode = UserDefaults.standard.integer(forKey: GalleryGridController.columnsKey) == 1 ? .list : .grid
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layout = makeLayout(mode)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        touchRecorder.cancelsTouchesInView = false
        touchRecorder.delaysTouchesEnded = false
        touchRecorder.onTouchDown = { [weak self] point in self?.touchDown(at: point) }
        collectionView.addGestureRecognizer(touchRecorder)
        view.addSubview(collectionView)
        setContentScrollView(collectionView)          // large title collapses with the grid

        let registration = UICollectionView.CellRegistration<DesignCell, UUID> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        configureNavigationItem()
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isContextMenuActive = false
        updateTimer()
        // Next turn: the screen that was just popped has torn its SwiftUI down by then.
        DispatchQueue.main.async { [weak self] in self?.settle() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateTimer()
    }

    // MARK: Data in

    /// Every design, newest first (the SwiftUI @Query result).
    func setDesigns(_ designs: [Design]) {
        var order: [UUID] = []
        var byID: [UUID: Design] = [:]
        for design in designs where !design.isDeleted {
            let id = design.id
            guard byID[id] == nil else { continue }        // `id` isn't unique-constrained (CloudKit)
            byID[id] = design
            order.append(id)
            if tracked[id] != ObjectIdentifier(design) {
                track(design, id: id)
            } else {
                contents[id] = DesignTileContent(design)    // CloudKit merges can bypass Observation
            }
        }
        let removed = Set(designsByID.keys).subtracting(byID.keys)
        for id in removed {
            contents[id] = nil
            tracked[id] = nil
        }
        orderedIDs = order
        designsByID = byID
        hasData = true
        if !removed.isEmpty {
            DesignImagePipeline.shared.forget(designIDs: removed)
            // Not inside SwiftUI's update pass (this is called from updateUIViewController).
            DispatchQueue.main.async { [weak self] in self?.router?.designsWereDeleted(removed) }
        }
        scheduleRefresh()
    }

    /// One Observation registration per design, renewed each time it fires.
    private func track(_ design: Design, id: UUID) {
        let identity = ObjectIdentifier(design)
        tracked[id] = identity
        contents[id] = withObservationTracking {
            DesignTileContent(design)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.designDidChange(id: id, identity: identity)
            }
        }
    }

    private func designDidChange(id: UUID, identity: ObjectIdentifier) {
        guard tracked[id] == identity else { return }     // a stale registration
        tracked[id] = nil
        guard let design = designsByID[id], ObjectIdentifier(design) == identity,
              !design.isDeleted, design.modelContext != nil else { return }
        track(design, id: id)
        scheduleRefresh()
    }

    // MARK: Applying changes

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// `keepsOffscreenAnchor`: false for a change the user asked for (a filter), which animates
    /// like any other instead of holding what's on screen in place.
    private func refresh(animated preferAnimation: Bool = true, keepsOffscreenAnchor: Bool = true) {
        guard isViewLoaded, dataSource != nil, hasData else { return }
        let target = orderedIDs.filter { id in
            guard let content = contents[id] else { return false }
            return filter.includes(content)
        }
        let ratiosChanged = mode == .list && target.contains { layoutRatios[$0] != contents[$0]?.aspect }
        if !hasApplied || target != shownIDs || ratiosChanged { needsApply = true }

        if needsApply, let animated = structuralUpdateAllowed() {
            applySnapshot(target, animated: animated && preferAnimation, keepsOffscreenAnchor: keepsOffscreenAnchor)
        } else if hasApplied, !isReflowing, navigationController?.transitionCoordinator == nil {
            reconfigureChangedCells()
        }
        updateTimer()
    }

    /// nil: not now (a later event calls `refresh` again). Otherwise: whether to animate.
    private func structuralUpdateAllowed() -> Bool? {
        guard hasApplied else { return false }
        // A design is pushed: frozen until settle() runs on the way back.
        guard let navigationController, navigationController.topViewController === self else { return nil }
        if let coordinator = navigationController.transitionCoordinator ?? transitionCoordinator {
            settle(after: coordinator)
            return nil
        }
        guard view.window != nil else { return false }     // under a full-screen cover: nobody sees it
        if isContextMenuActive { return nil }
        if isReflowing || collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
            scheduleRetry()
            return nil                                      // never under a finger
        }
        return true
    }

    private func applySnapshot(_ ids: [UUID], animated: Bool, keepsOffscreenAnchor: Bool = true) {
        needsApply = false
        // Changes above what's on screen (an iCloud import, a Make Changes insert while scrolled
        // down) must not move what the user is looking at: no animation, offset kept.
        let anchor = hasApplied && keepsOffscreenAnchor ? offscreenChangeAnchor(for: ids) : nil
        let animate = animated && anchor == nil
        let wasShown = Set(shownIDs)
        let reconfigure = ids.filter { wasShown.contains($0) && contents[$0] != shownContents[$0] }
        let heightsChange = mode == .list && ids.contains { wasShown.contains($0) && layoutRatios[$0] != contents[$0]?.aspect }
        shownIDs = ids
        shownContents = [:]
        layoutRatios = [:]
        for id in ids {
            guard let content = contents[id] else { continue }
            shownContents[id] = content
            layoutRatios[id] = content.aspect
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(reconfigure)
        if animate { beginReflow() }
        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            if animate { self?.endReflow() }
        }
        if heightsChange {
            layout.invalidateLayout()
            if animate {
                beginReflow()
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    self.collectionView.layoutIfNeeded()
                } completion: { [weak self] _ in
                    self?.endReflow()
                }
            }
        }
        if let anchor { restore(anchor) }
        hasApplied = true
        setNeedsUpdateContentUnavailableConfiguration()
    }

    /// The first on-screen item that stays, if the items above the visible area change.
    private func offscreenChangeAnchor(for ids: [UUID]) -> ScrollAnchor? {
        let offset = collectionView.contentOffset.y
        let visibleTop = offset + collectionView.adjustedContentInset.top
        let kept = Set(ids)
        var above: [UUID] = []
        for (item, id) in shownIDs.enumerated() {
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else { return nil }
            if frame.maxY <= visibleTop {
                above.append(id)
            } else if kept.contains(id) {
                guard !above.isEmpty else { return nil }
                let unchanged = Array(ids.prefix(above.count)) == above
                    && !(mode == .list && above.contains { layoutRatios[$0] != contents[$0]?.aspect })
                return unchanged ? nil : ScrollAnchor(id: id, offset: frame.minY - offset)
            }
        }
        return nil
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard let indexPath = dataSource.indexPath(for: anchor.id) else { return }
        collectionView.layoutIfNeeded()
        guard let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let insets = collectionView.adjustedContentInset
        let maxY = max(-insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        let y = min(max(frame.minY - anchor.offset, -insets.top), maxY)
        collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: y)
    }

    /// Status / favourite / title changes: same cells, same places.
    private func reconfigureChangedCells() {
        let changed = shownIDs.filter { id in
            guard let content = contents[id] else { return false }
            return content != shownContents[id]
        }
        guard !changed.isEmpty else { return }
        // Visible cells are configured directly: a non-animated apply runs the cell provider
        // without animations, which would snap the tiles' own fades (heart, pending → done).
        var offscreen: [UUID] = []
        for id in changed {
            shownContents[id] = contents[id]
            if let indexPath = dataSource.indexPath(for: id),
               let cell = collectionView.cellForItem(at: indexPath) as? DesignCell,
               cell.designID == id {
                configure(cell, id: id)
            } else {
                offscreen.append(id)
            }
        }
        guard !offscreen.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(offscreen)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.needsApply { self.refresh() }
        }
    }

    // MARK: Cells in motion

    /// Cells are moving (animated apply, layout switch, list heights). Capped at 1 s, so a
    /// completion that never comes can't hold taps back.
    private var isReflowing: Bool {
        reflows > 0 && CACurrentMediaTime() - reflowStart < 1
    }

    private func beginReflow() {
        if !isReflowing {
            reflows = 0
            reflowStart = CACurrentMediaTime()
        }
        reflows += 1
    }

    private func endReflow() {
        reflows = max(0, reflows - 1)
        guard reflows == 0 else { return }
        openQueued()
        if needsApply { scheduleRefresh() }
    }

    /// Hit-testing uses where cells will end up; while they move, note what's drawn under the
    /// finger instead, at the moment it lands.
    private func touchDown(at point: CGPoint) {
        tapDuringReflow = isReflowing
        drawnTapID = tapDuringReflow ? drawnDesign(at: point) : nil
    }

    private func drawnDesign(at point: CGPoint) -> UUID? {
        for case let cell as DesignCell in collectionView.subviews.reversed() where !cell.isHidden && cell.alpha > 0 {
            let frame = cell.layer.presentation()?.frame ?? cell.frame
            if frame.contains(point) { return cell.designID }
        }
        return nil
    }

    // MARK: Coming back from a design

    /// Runs once the grid is on screen again and the zoom back has completely finished
    /// (or right before another design is pushed, whichever comes first).
    func runWhenBack(from owner: UIViewController, _ action: @escaping () -> Void) {
        afterReturn.append((owner: ObjectIdentifier(owner), action: action))
    }

    /// `owner` is showing again (its pop was cancelled): what it queued must not run on some
    /// later return. Other screens' actions stay; a tap queued for the grid is dropped.
    func discardReturnActions(from owner: UIViewController) {
        let id = ObjectIdentifier(owner)
        afterReturn.removeAll { $0.owner == id }
        queuedOpenID = nil
    }

    /// Another design is about to be pushed: what the previous one queued runs now, so it is
    /// never lost (the snapshot is frozen from here on, so deleting or inserting is safe).
    func runReturnActionsNow() {
        let actions = afterReturn
        afterReturn = []
        for entry in actions { entry.action() }
    }

    /// Called when a navigation transition ends. If the grid is on top, run what waited for it.
    func settle() {
        guard let navigationController, navigationController.topViewController === self else {
            refresh()
            return
        }
        if let coordinator = navigationController.transitionCoordinator {
            settle(after: coordinator)
            return
        }
        isWaitingForTransition = false          // no transition: nothing can still be pending
        let actions = afterReturn
        afterReturn = []
        for entry in actions { entry.action() }
        refresh()
        openQueued()
    }

    /// `settle()` again once `coordinator`'s transition is over.
    private func settle(after coordinator: UIViewControllerTransitionCoordinator) {
        guard !isWaitingForTransition else { return }
        isWaitingForTransition = true
        let registered = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isWaitingForTransition = false
                self?.settle()
            }
        }
        guard !registered else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isWaitingForTransition = false
            self?.settle()
        }
    }

    /// The view UIKit zooms from and back into: the cell for this id, looked up every time
    /// (cells are reused) and, when closing, scrolled fully into view first (as Photos does).
    /// While a design is pushed the snapshot is frozen, so the id is always here.
    func zoomSourceView(for id: UUID, scrollIntoView: Bool) -> UIView? {
        guard isViewLoaded, let indexPath = dataSource.indexPath(for: id) else { return nil }
        collectionView.layoutIfNeeded()
        if scrollIntoView, let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            if !visible.contains(frame) {
                let position: UICollectionView.ScrollPosition = frame.midY < visible.midY ? .top : .bottom
                collectionView.scrollToItem(at: indexPath, at: position, animated: false)
                collectionView.layoutIfNeeded()
            }
        }
        return (collectionView.cellForItem(at: indexPath) as? DesignCell)?.tile
    }

    // MARK: Cells

    private func configure(_ cell: DesignCell, id: UUID) {
        guard let content = shownContents[id] ?? contents[id] else { return }
        cell.configure(content, mode: mode, image: imageRequest(for: content, mode: mode)) { [weak self] in
            self?.retry(id)
        }
    }

    private func imageRequest(for content: DesignTileContent, mode: GalleryMetrics.Mode) -> DesignImageRequest {
        guard content.status == .completed else {
            // Only ever seen under a material: a tiny decode is plenty.
            return DesignImageRequest(designID: content.id, kind: .original, maxPixelSize: 96)
        }
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        let size = GalleryMetrics.cellSize(mode: mode, width: width, ratio: content.aspect)
        return .aspectFill(designID: content.id, kind: .result, size: size,
                           scale: traitCollection.displayScale, imageAspect: content.aspect)
    }

    private func makeLayout(_ mode: GalleryMetrics.Mode) -> GalleryLayout {
        let layout = GalleryLayout(mode: mode)
        layout.ratioProvider = { [weak self] indexPath in
            guard let self, let id = self.dataSource?.itemIdentifier(for: indexPath) else { return AspectRatio.gridCard.value }
            return self.layoutRatios[id] ?? AspectRatio.gridCard.value
        }
        return layout
    }

    private func retry(_ id: UUID) {
        guard let design = designsByID[id], !design.isDeleted, design.modelContext != nil else { return }
        router?.generation.retry(design)
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        isContextMenuActive = false
        // The design that was drawn under the finger: the tapped cell's, or while cells were
        // moving, the one noted at touch-down.
        let id = tapDuringReflow
            ? drawnTapID
            : (collectionView.cellForItem(at: indexPath) as? DesignCell)?.designID ?? dataSource.itemIdentifier(for: indexPath)
        tapDuringReflow = false
        drawnTapID = nil
        guard let id else { return }
        // Cells still moving, or a zoom back to the grid still running: open once settled
        // (after what the closed design queued has run). Never push in the middle of a pop.
        if let coordinator = navigationController?.transitionCoordinator {
            guard navigationController?.topViewController === self else { return }   // a push is running
            if coordinator.viewController(forKey: .to) === self {
                queuedOpenID = id                   // didShow → settle() opens it
                return
            }
        }
        if isReflowing {
            queuedOpenID = id
            return
        }
        open(id)
    }

    private func open(_ id: UUID) {
        // A deleted-and-saved model reads `isDeleted == false` but has no context any more.
        guard let design = designsByID[id], !design.isDeleted, design.modelContext != nil,
              dataSource.indexPath(for: id) != nil else { return }      // no cell = nothing to zoom from
        router?.openDesign(design, from: self)
    }

    private func openQueued() {
        guard let id = queuedOpenID, !isReflowing,
              let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil else { return }
        queuedOpenID = nil
        open(id)
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        if needsApply { scheduleRefresh() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isContextMenuActive = false
        queuedOpenID = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleRefresh() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleRefresh()
    }

    // MARK: Prefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), let content = shownContents[id] else { continue }
            let request = imageRequest(for: content, mode: mode)
            let key = request.key
            guard prefetchTokens[key] == nil else { continue }
            let token = DesignImagePipeline.shared.load(request, priority: .low) { [weak self] _ in
                self?.prefetchTokens[key] = nil
            }
            if let token { prefetchTokens[key] = token }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), let content = shownContents[id] else { continue }
            let key = imageRequest(for: content, mode: mode).key
            DesignImagePipeline.shared.cancel(prefetchTokens.removeValue(forKey: key))
        }
    }

    // MARK: Context menu

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath), shownContents[id] != nil else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: { [weak self] in
            self?.makePreview(for: id)
        }, actionProvider: { [weak self] _ in
            self?.makeMenu(for: id)
        })
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        isContextMenuActive = true
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        guard let animator else {
            contextMenuDidEnd()
            return
        }
        animator.addCompletion { [weak self] in
            self?.contextMenuDidEnd()
        }
    }

    private func contextMenuDidEnd() {
        isContextMenuActive = false
        if let id = deleteAfterMenu {
            deleteAfterMenu = nil
            confirmDelete(id)
        }
        scheduleRefresh()
    }

    private func makeMenu(for id: UUID) -> UIMenu? {
        guard let design = designsByID[id], !design.isDeleted, design.modelContext != nil else { return nil }
        var actions: [UIMenuElement] = [
            UIAction(title: design.isFavorite ? "Unfavorite" : "Favorite",
                     image: UIImage(systemName: design.isFavorite ? "heart.slash" : "heart")) { _ in
                design.isFavorite.toggle()
            },
        ]
        if design.isRetryable {
            actions.append(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.retry(id)
            })
        }
        let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            // The confirmation is presented once the menu is gone.
            if self.isContextMenuActive { self.deleteAfterMenu = id } else { self.confirmDelete(id) }
        }
        return UIMenu(title: "", children: [
            UIMenu(title: "", options: .displayInline, children: actions),
            UIMenu(title: "", options: .displayInline, children: [delete]),
        ])
    }

    /// The list-style card at 300 pt, as before (own ratio, pending state included).
    private func makePreview(for id: UUID) -> UIViewController? {
        guard let content = shownContents[id] ?? contents[id] else { return nil }
        let width: CGFloat = 300
        let height = min(width / max(content.aspect, 0.1), view.bounds.height * 0.7)
        let tile = DesignTileView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let request: DesignImageRequest = content.status == .completed
            ? .aspectFill(designID: id, kind: .result, size: tile.bounds.size,
                          scale: traitCollection.displayScale, imageAspect: content.aspect)
            : DesignImageRequest(designID: id, kind: .original, maxPixelSize: 96)
        tile.configure(content, cornerRadius: 0, compact: false, image: request) { [weak self] in
            self?.retry(id)
        }
        previewTile = tile
        let preview = UIViewController()
        preview.view = tile
        preview.preferredContentSize = tile.bounds.size
        return preview
    }

    private func confirmDelete(_ id: UUID) {
        guard designsByID[id] != nil else { return }
        let alert = UIAlertController(title: "Delete this design?", message: "It will be removed from all your devices.", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete Design", style: .destructive) { [weak self] _ in
            guard let self, let design = self.designsByID[id], !design.isDeleted else { return }
            self.router?.generation.delete(design)       // the grid animates the removal
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let indexPath = dataSource.indexPath(for: id), let cell = collectionView.cellForItem(at: indexPath) {
            alert.popoverPresentationController?.sourceView = cell
            alert.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }

    // MARK: Toolbar

    private func configureNavigationItem() {
        navigationItem.title = filter.title
        navigationItem.largeTitleDisplayMode = .always
        optionsItem.accessibilityLabel = "Options"
        addItem.accessibilityLabel = "New Design"
        addItem.menu = UIMenu(title: "", children: [
            UIAction(title: "Redesign a Room", image: UIImage(systemName: "sofa")) { [weak self] _ in
                self?.router?.create(.interior)
            },
            UIAction(title: "Design a Garden", image: UIImage(systemName: "leaf")) { [weak self] _ in
                self?.router?.create(.garden)
            },
        ])
        navigationItem.rightBarButtonItems = [addItem, optionsItem]   // right to left: "+" outermost
        updateOptionsItem(animated: false)
    }

    private func updateOptionsItem(animated: Bool) {
        let symbol = filter == .all ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill"
        if symbol != optionsSymbol, let image = UIImage(systemName: symbol) {
            if animated, optionsSymbol != nil {
                optionsItem.setSymbolImage(image, contentTransition: .replace)
            } else {
                optionsItem.image = image
            }
            optionsSymbol = symbol
        }
        optionsItem.menu = makeOptionsMenu()
    }

    private func makeOptionsMenu() -> UIMenu {
        let filters = GalleryFilter.allCases.map { option in
            UIAction(title: option.rawValue, image: UIImage(systemName: option.symbol), state: option == filter ? .on : .off) { [weak self] _ in
                self?.setFilter(option, animated: true)
            }
        }
        let layouts: [(GalleryMetrics.Mode, String, String)] = [(.grid, "Grid", "square.grid.2x2"), (.list, "List", "rectangle.grid.1x2")]
        let layoutActions = layouts.map { option, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol), state: option == mode ? .on : .off) { [weak self] _ in
                self?.setMode(option)
            }
        }
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.router?.showSettings()
        }
        return UIMenu(title: "", children: [
            UIMenu(title: "", options: [.displayInline, .singleSelection], children: filters),
            UIMenu(title: "View As", options: [.displayInline, .singleSelection], children: layoutActions),
            UIMenu(title: "", options: .displayInline, children: [settings]),
        ])
    }

    private func setFilter(_ newFilter: GalleryFilter, animated: Bool) {
        guard newFilter != filter else { return }
        filter = newFilter
        navigationItem.title = newFilter.title
        // Empty before and after (Favorites → Gardens): no snapshot is applied, the message still changes.
        setNeedsUpdateContentUnavailableConfiguration()
        selectionFeedback.selectionChanged()
        updateOptionsItem(animated: true)
        refresh(animated: animated, keepsOffscreenAnchor: false)
    }

    private func setMode(_ newMode: GalleryMetrics.Mode) {
        guard newMode != mode, isViewLoaded else { return }
        let anchor = collectionView.indexPathsForVisibleItems.min()
        mode = newMode
        UserDefaults.standard.set(newMode == .list ? 1 : 2, forKey: Self.columnsKey)
        selectionFeedback.selectionChanged()
        updateOptionsItem(animated: false)
        for case let cell as DesignCell in collectionView.visibleCells {
            if let id = cell.designID { configure(cell, id: id) }
        }
        // Grid mode doesn't use the ratios, so they may be behind (a design completed meanwhile).
        for id in shownIDs {
            if let content = shownContents[id] { layoutRatios[id] = content.aspect }
        }
        let newLayout = makeLayout(newMode)
        newLayout.anchor = anchor
        layout = newLayout
        beginReflow()
        collectionView.setCollectionViewLayout(newLayout, animated: true) { [weak self, weak newLayout] _ in
            newLayout?.anchor = nil
            self?.reconfigureAll()
            self?.endReflow()
        }
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Empty state

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard hasApplied, shownIDs.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        let filter = self.filter
        contentUnavailableConfiguration = UIHostingConfiguration {
            GalleryEmptyState(
                filter: filter,
                onCreate: { [weak self] kind in self?.router?.create(kind) },
                onShowAll: { [weak self] in self?.setFilter(.all, animated: false) }
            )
        }
    }

    // MARK: Timers of pending designs (one ticking clock, visible cells only)

    private func updateTimer() {
        let needed = isViewLoaded && view.window != nil && shownContents.values.contains { $0.status.isInProgress }
        if needed, timer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    @objc private func tick() {
        for case let cell as DesignCell in collectionView.visibleCells {
            cell.tile.updateTimer()
        }
        previewTile?.updateTimer()
    }
}

/// Notes where each touch lands, the moment it lands, and takes no further part in recognition.
private final class TouchDownRecorder: UIGestureRecognizer {
    var onTouchDown: (CGPoint) -> Void = { _ in }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onTouchDown(touch.location(in: view)) }
        state = .failed
    }
}
