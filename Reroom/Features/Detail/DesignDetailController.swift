import LinkPresentation
import Observation
import SwiftData
import SwiftUI
import Symbols
import UIKit

@Observable
final class DesignDetailState {
    enum Mode: String, CaseIterable { case design = "Design", compare = "Before & After" }
    enum SaveState: Equatable { case idle, saving, saved }

    var result: UIImage?
    var original: UIImage?
    /// The result's average colour, under the hero until the picture is there.
    var placeholder: UIColor?
    var mode: Mode = .design
    var saveState: SaveState = .idle
    var saveError: String?
}

/// The design page, pushed from the grid with the zoom. SwiftUI draws the content
/// (`DesignDetailView`); UIKit owns the chrome — title, ⋯ menu, bottom toolbar — so it is in place
/// on the first frame of the zoom, and owns every navigation step (sheet, confirmation, pop) so
/// they happen strictly one after another.
final class DesignDetailController: SpineHostingController {
    let design: Design
    let designID: UUID
    let state = DesignDetailState()
    /// Where the hero is, whatever it shows: the rect the grid cell is lined up with.
    let heroAnchor = ViewBox()
    /// The hero's image view: the photo viewer zooms out of it.
    let heroImage = ViewBox()

    private weak var router: GalleryRouter?
    private var isTornDown = false
    private var observation = 0
    private var shownStatus: DesignStatus?
    private var shownFavorite: Bool?
    private var shownSaveState: DesignDetailState.SaveState?
    private var shownShare: Bool?
    private var resultToken: DesignImagePipeline.Token?
    private var originalToken: DesignImagePipeline.Token?
    /// On the way back when the hero can't be lined up: the page fades into the picture here.
    private var endpointCover: UIView?
    private var endpointFrame: CGRect?
    /// The design's aspect, kept so the resting hero frame never reads a deleted model.
    private var heroAspect: CGFloat

    private lazy var moreItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: nil)
    private lazy var favoriteItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "heart"), primaryAction: UIAction(image: UIImage(systemName: "heart")) { [weak self] _ in
        self?.toggleFavorite()
    }, menu: nil)
    private lazy var saveItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "square.and.arrow.down"), primaryAction: UIAction(image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
        self?.saveToPhotos()
    }, menu: nil)
    private lazy var shareItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction(image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        self?.share()
    }, menu: nil)
    private lazy var makeChangesItem: UIBarButtonItem = {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Make Changes"
        configuration.image = UIImage(systemName: "wand.and.sparkles")
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction(title: "Make Changes") { [weak self] _ in
            self?.presentMakeChanges()
        }, for: .primaryActionTriggered)
        button.sizeToFit()
        let item = UIBarButtonItem(customView: button)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Liquid Glass would put the capsule inside a second, shared glass capsule.
            item.hidesSharedBackground = true
        }
        #endif
        return item
    }()

    init(design: Design, router: GalleryRouter) {
        self.design = design
        self.designID = design.id
        self.router = router
        self.heroAspect = design.aspectRatio.value
        super.init(rootView: AnyView(EmptyView()))
        // The first frame of the zoom already shows the picture: whatever size is decoded (the grid's).
        let pipeline = DesignImagePipeline.shared
        state.result = pipeline.bestCachedImage(designID: designID, kind: .result)
        state.original = pipeline.bestCachedImage(designID: designID, kind: .original)
        state.placeholder = pipeline.averageColor(designID: designID, kind: .result)
        rootView = router.host(DesignDetailView(
            design: design,
            state: state,
            heroAnchor: heroAnchor,
            heroImage: heroImage,
            actions: DesignDetailActions(
                openViewer: { [weak self] in self?.openViewer() },
                openPlant: { [weak self] plant in self?.openPlant(plant) }
            )
        ))
        navigationItem.title = design.styleTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = moreItem
        moreItem.accessibilityLabel = "More"
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersToolbarVisible: Bool {
        !isTornDown && !design.isDeleted && design.modelContext != nil && design.status == .completed
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChrome()
        loadImages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.rightBarButtonItem = moreItem       // UIKit owns this item
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        removeEndpointCover()
        router?.designScreenDidAppear(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent, animated { prepareClosingEndpoint() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { tearDown() }
    }

    // MARK: Zoom

    /// The rect the grid cell lines up with, cropped to the cell's shape (`sourceSize`): the hero,
    /// or on the way back, when the hero is scrolled away or showing Before & After, the picture
    /// the page fades into.
    func heroAlignmentRect(sourceSize: CGSize) -> CGRect {
        let aspect = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 0
        // Deleted elsewhere: the page is torn down, the cover built before that is what closes.
        if let endpointFrame { return endpointFrame.centeredCrop(aspect: aspect) }
        guard isViewLoaded, !isTornDown else { return .null }
        let isClosing = navigationController.map { $0.topViewController !== self } ?? false
        if isClosing { prepareClosingEndpoint() }
        if let endpointFrame { return endpointFrame.centeredCrop(aspect: aspect) }
        view.layoutIfNeeded()
        return (visibleHeroFrame() ?? restingHeroFrame()).centeredCrop(aspect: aspect)
    }

    /// The hero's frame in this screen, if all of it is on screen.
    private func visibleHeroFrame() -> CGRect? {
        guard let hero = heroAnchor.view, hero.isDescendant(of: view) else { return nil }
        let rect = hero.convert(hero.bounds, to: view)
        guard rect.width > 1, rect.height > 1, view.bounds.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
        return rect
    }

    /// Where the hero sits with the page scrolled to the top.
    private func restingHeroFrame() -> CGRect {
        let bounds = view.bounds
        let insets = view.safeAreaInsets
        let margin = max(view.directionalLayoutMargins.leading, 16)
        var width = max(bounds.width - 2 * margin, 1)
        var height = width / max(heroAspect, 0.1)
        let available = bounds.height - insets.top - insets.bottom - 32
        if height > available, available > 0 {
            width *= available / height
            height = available
        }
        return CGRect(x: (bounds.width - width) / 2, y: insets.top + 16, width: width, height: height)
    }

    /// Going back while the hero can't be lined up with the cell: fade the page into the picture
    /// (alongside the zoom, reversed if the swipe is cancelled), so what shrinks into the cell is
    /// the picture — never the white list.
    private func prepareClosingEndpoint() {
        guard endpointFrame == nil, isViewLoaded, !isTornDown, !design.isDeleted, design.modelContext != nil,
              design.status == .completed,
              let image = state.result ?? DesignImagePipeline.shared.bestCachedImage(designID: designID, kind: .result) else { return }
        view.layoutIfNeeded()
        let hero = visibleHeroFrame()
        if hero != nil, state.mode == .design { return }        // the hero itself lines up
        let backdrop = addEndpointCover(image: image, frame: hero ?? restingHeroFrame())
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: { _ in backdrop.alpha = 1 }, completion: { [weak self] context in
               if context.isCancelled { self?.removeEndpointCover() }
           }) {
            return
        }
        UIView.animate(withDuration: 0.25) { backdrop.alpha = 1 }
    }

    /// The picture at `frame` on a plain page, above the SwiftUI content (transparent at first).
    @discardableResult
    private func addEndpointCover(image: UIImage, frame: CGRect) -> UIView {
        let backdrop = UIView(frame: view.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .systemGroupedBackground
        backdrop.isUserInteractionEnabled = false
        backdrop.alpha = 0
        let picture = UIImageView(image: image)
        picture.frame = frame
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 12
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = state.placeholder
        backdrop.addSubview(picture)
        view.addSubview(backdrop)
        endpointCover = backdrop
        endpointFrame = frame
        return backdrop
    }

    private func removeEndpointCover() {
        endpointCover?.removeFromSuperview()
        endpointCover = nil
        endpointFrame = nil
    }

    // MARK: Chrome (follows the model through Observation)

    private func observeChrome() {
        observation += 1
        let generation = observation
        withObservationTracking {
            applyChrome()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observation == generation, !self.isTornDown else { return }
                self.observeChrome()
            }
        }
    }

    private func applyChrome() {
        guard !isTornDown, !design.isDeleted, design.modelContext != nil else { return }
        let status = design.status
        let completed = status == .completed
        let favorite = design.isFavorite
        heroAspect = design.aspectRatio.value
        let hasResult = state.result != nil

        navigationItem.title = design.styleTitle
        moreItem.menu = makeMoreMenu(retryable: design.isRetryable, canView: completed && hasResult)

        if favorite != shownFavorite, let image = UIImage(systemName: favorite ? "heart.fill" : "heart") {
            if shownFavorite == nil {
                favoriteItem.image = image
            } else {
                favoriteItem.setSymbolImage(image, contentTransition: .replace)
                favoriteItem.playSymbolEffect(.bounce)
            }
            shownFavorite = favorite
        }
        favoriteItem.tintColor = favorite ? .systemPink : nil
        favoriteItem.accessibilityLabel = favorite ? "Unfavorite" : "Favorite"

        let saveState = state.saveState
        if saveState != shownSaveState, let image = UIImage(systemName: saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down") {
            if shownSaveState == nil { saveItem.image = image } else { saveItem.setSymbolImage(image, contentTransition: .replace) }
            if saveState == .saving { saveItem.runSymbolEffect(.pulse) } else { saveItem.removeAllSymbolEffects() }
            saveItem.isEnabled = saveState != .saving
            saveItem.accessibilityLabel = "Save to Photos"
            shownSaveState = saveState
        }

        if hasResult != shownShare {
            shownShare = hasResult
            var items: [UIBarButtonItem] = [favoriteItem, .flexibleSpace(), saveItem, .flexibleSpace()]
            if hasResult { items += [shareItem, .flexibleSpace()] }
            items.append(makeChangesItem)
            setToolbarItems(items, animated: false)
        }

        if status != shownStatus {
            let isFirst = shownStatus == nil
            shownStatus = status
            if !isFirst {
                // Outside the tracking pass: loading writes to `state`.
                DispatchQueue.main.async { [weak self] in self?.loadImages() }
                if let navigationController, navigationController.topViewController === self,
                   navigationController.transitionCoordinator == nil {
                    navigationController.setToolbarHidden(!completed, animated: true)
                }
            }
        }
    }

    private func makeMoreMenu(retryable: Bool, canView: Bool) -> UIMenu {
        var children: [UIMenuElement] = []
        if retryable {
            children.append(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                guard let self, !self.design.isDeleted else { return }
                self.router?.generation.retry(self.design)
            })
        }
        if canView {
            children.append(UIAction(title: "View Full Screen", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.openViewer()
            })
        }
        children.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDelete()
        })
        return UIMenu(title: "", children: children)
    }

    // MARK: Images

    /// Hero-size result and original (compare, pending backdrop), off the main thread, cached on disk.
    private func loadImages() {
        guard !isTornDown, !design.isDeleted, design.modelContext != nil else { return }
        let pipeline = DesignImagePipeline.shared
        let screenWidth = navigationController?.view.bounds.width ?? view.bounds.width
        let width = max(screenWidth - 40, 200)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let aspect = max(design.aspectRatio.value, 0.1)
        let longEdge = max(width, width / aspect) * scale      // aspect-fit at the design's own ratio
        if design.status == .completed {
            pipeline.cancel(resultToken)
            resultToken = pipeline.load(DesignImageRequest(designID: designID, kind: .result, maxPixelSize: longEdge), priority: .veryHigh) { [weak self] image in
                guard let self, let image else { return }
                self.state.result = image
                self.state.placeholder = pipeline.averageColor(designID: self.designID, kind: .result)
            }
        }
        pipeline.cancel(originalToken)
        originalToken = pipeline.load(DesignImageRequest(designID: designID, kind: .original, maxPixelSize: longEdge), priority: .high) { [weak self] image in
            if let image { self?.state.original = image }
        }
    }

    // MARK: Actions

    private func toggleFavorite() {
        guard !design.isDeleted else { return }
        design.isFavorite.toggle()
    }

    private func saveToPhotos() {
        guard state.saveState != .saving, !design.isDeleted, let data = design.resultImageData else { return }
        state.saveState = .saving
        state.saveError = nil
        Task { [weak self] in
            do {
                try await PhotoLibrarySaver.save(imageData: data)
                self?.state.saveState = .saved
                try? await Task.sleep(for: .seconds(2))
                self?.state.saveState = .idle
            } catch {
                self?.state.saveState = .idle
                self?.state.saveError = error.localizedDescription
            }
        }
    }

    private func share() {
        guard let preview = state.result, !design.isDeleted else { return }
        let image = design.resultImageData.flatMap { UIImage(data: $0) } ?? preview
        let controller = UIActivityViewController(activityItems: [DesignShareItem(image: image, title: "Reroom design")], applicationActivities: nil)
        controller.popoverPresentationController?.sourceItem = shareItem
        present(controller, animated: true)
    }

    private func openViewer() {
        guard let result = state.result else { return }
        guard state.mode == .design else {
            // The viewer zooms out of the picture: show it first, push on the next turn.
            state.mode = .design
            DispatchQueue.main.async { [weak self] in self?.openViewer() }
            return
        }
        // The viewer zooms out of the hero and back into it: scrolled away, the List may have
        // released its view (UIKit would zoom from the centre). Scroll to the top, push next turn.
        if visibleHeroFrame() == nil, let list = firstScrollView(in: view) {
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: -list.adjustedContentInset.top), animated: false)
            view.layoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown, self.state.mode == .design, let result = self.state.result else { return }
                self.router?.openViewer(from: self, result: result, original: self.state.original)
            }
            return
        }
        router?.openViewer(from: self, result: result, original: state.original)
    }

    private func firstScrollView(in root: UIView) -> UIScrollView? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView { return scrollView }
            queue += view.subviews
        }
        return nil
    }

    private func openPlant(_ plant: Plant) {
        router?.openPlant(plant, locationName: design.locationName)
    }

    private func presentMakeChanges() {
        guard let router, presentedViewController == nil, !design.isDeleted else { return }
        let sheet = UIHostingController(rootView: AnyView(EmptyView()))
        sheet.rootView = router.host(MakeChangesSheet(
            design: design,
            onCancel: { [weak sheet] in sheet?.dismiss(animated: true) },
            onApply: { [weak self] change in self?.applyChange(change) }
        ))
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    /// Sheet slides away → zoom back into the cell → only then the new design is inserted.
    private func applyChange(_ change: String) {
        guard let router else { return }
        let generation = router.generation
        let source = design
        router.close(self) { _ = generation.makeChanges(from: source, change: change) }
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: "Delete this design?", message: "It will be removed from all your devices.", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete Design", style: .destructive) { [weak self] _ in
            guard let self, let router = self.router else { return }
            let generation = router.generation
            let design = self.design
            // Back to the grid first; deleted once the zoom has landed (never read after delete).
            router.close(self) { if !design.isDeleted { generation.delete(design) } }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceItem = moreItem
        present(alert, animated: true)
    }

    // MARK: Teardown

    func designWasDeleted() {
        // The zoom back must shrink the picture into the cell, not the torn-down blank page:
        // put the picture up (from pixels already decoded, no model reads) before tearing down.
        if endpointFrame == nil, isViewLoaded, !isTornDown,
           let image = state.result ?? state.original {
            view.layoutIfNeeded()
            let cover = addEndpointCover(image: image, frame: visibleHeroFrame() ?? restingHeroFrame())
            cover.alpha = 1
        }
        tearDown()
    }

    /// Once popped (or deleted elsewhere) the SwiftUI tree goes, so nothing reads the model again.
    private func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        observation += 1
        DesignImagePipeline.shared.cancel(resultToken)
        DesignImagePipeline.shared.cancel(originalToken)
        rootView = AnyView(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

/// Shares a picture with a titled preview in the share sheet (what ShareLink's SharePreview showed).
final class DesignShareItem: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        return metadata
    }
}

extension UIBarButtonItem {
    /// Runs `effect` until removed (see `UIImageView.runSymbolEffect`).
    func runSymbolEffect<Effect: IndefiniteSymbolEffect & SymbolEffect>(_ effect: Effect) {
        addSymbolEffect(effect)
    }

    /// Plays `effect` once.
    func playSymbolEffect<Effect: DiscreteSymbolEffect & SymbolEffect>(_ effect: Effect) {
        addSymbolEffect(effect)
    }
}
