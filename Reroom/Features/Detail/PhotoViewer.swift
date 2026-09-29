import Observation
import SwiftData
import SwiftUI
import Symbols
import UIKit

@Observable
final class PhotoViewerState {
    var result: UIImage
    var original: UIImage?
    var chromeHidden = false
    var showingOriginal = false

    init(result: UIImage, original: UIImage?) {
        self.result = result
        self.original = original
    }
}

/// Full-screen viewer that behaves like a photo in Photos: pushed with the zoom out of the hero,
/// swipe down (at 1×) or edge swipe back into it; pinch / double-tap zoom; tap hides the bars on
/// black; press and hold (or Compare) shows the original.
final class PhotoViewerController: SpineHostingController {
    let design: Design
    let state: PhotoViewerState
    let zoomBox = ViewBox()

    private weak var router: GalleryRouter?
    private var isTornDown = false
    private var observation = 0
    private var shownFavorite: Bool?
    private var shownOriginal: Bool?
    private var tokens: [DesignImagePipeline.Token] = []
    private var savedToolbarEdgeAppearance: UIToolbarAppearance?

    private lazy var shareItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction(image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        self?.share()
    }, menu: nil)
    private lazy var favoriteItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "heart"), primaryAction: UIAction(image: UIImage(systemName: "heart")) { [weak self] _ in
        self?.toggleFavorite()
    }, menu: nil)
    private lazy var compareItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "square.split.2x1"), primaryAction: UIAction(image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
        self?.state.showingOriginal.toggle()
    }, menu: nil)

    init(design: Design, result: UIImage, original: UIImage?, router: GalleryRouter) {
        self.design = design
        self.state = PhotoViewerState(result: result, original: original)
        self.router = router
        super.init(rootView: AnyView(EmptyView()))
        rootView = router.host(PhotoViewerContent(design: design, state: state, zoomBox: zoomBox, onTap: { [weak self] in
            self?.toggleChrome()
        }))
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = makeTitleView()
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()     // was .toolbarBackground(.visible)
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        toolbarItems = [shareItem, .flexibleSpace(), favoriteItem, .flexibleSpace(), compareItem]
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersToolbarVisible: Bool { !state.chromeHidden }
    override var prefersNavigationBarHidden: Bool { state.chromeHidden }

    var isAtMinimumZoom: Bool {
        (zoomBox.view as? PhotoZoomScrollView)?.isAtMinimumZoom ?? true
    }

    /// Where the photo is drawn, cropped to the hero's shape (`sourceSize`): the rect the hero is
    /// lined up with.
    func imageAlignmentRect(sourceSize: CGSize) -> CGRect {
        guard isViewLoaded, !isTornDown else { return .null }
        view.layoutIfNeeded()
        guard let zoom = zoomBox.view as? PhotoZoomScrollView, let frame = zoom.imageFrame(in: view) else { return .null }
        return frame.centeredCrop(aspect: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChrome()
        loadFullSize()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        router?.setStatusBarHidden(state.chromeHidden)
        // Keep the toolbar's background over the photo (the old `.toolbarBackground(.visible)`).
        if let toolbar = navigationController?.toolbar {
            savedToolbarEdgeAppearance = toolbar.scrollEdgeAppearance
            let appearance = UIToolbarAppearance()
            appearance.configureWithDefaultBackground()
            toolbar.scrollEdgeAppearance = appearance
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        router?.setStatusBarHidden(false)
        navigationController?.toolbar.scrollEdgeAppearance = savedToolbarEdgeAppearance
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { tearDown() }
    }

    func designWasDeleted() {
        tearDown()
    }

    private func toggleChrome() {
        let hidden = !state.chromeHidden
        withAnimation(.easeInOut(duration: 0.2)) { state.chromeHidden = hidden }
        navigationController?.setNavigationBarHidden(hidden, animated: true)
        navigationController?.setToolbarHidden(hidden, animated: true)
        router?.setStatusBarHidden(hidden)
    }

    private func toggleFavorite() {
        guard !isTornDown, !design.isDeleted else { return }
        design.isFavorite.toggle()
    }

    /// The hero handed over its (screen-size) picture; swap in the full-size one without touching
    /// the zoom (PhotoZoomScrollView keeps its frame for the same aspect ratio).
    private func loadFullSize() {
        let pipeline = DesignImagePipeline.shared
        let id = design.id
        if let token = pipeline.load(DesignImageRequest(designID: id, kind: .result, maxPixelSize: 3072), priority: .veryHigh, completion: { [weak self] image in
            if let image { self?.state.result = image }
        }) {
            tokens.append(token)
        }
        if let token = pipeline.load(DesignImageRequest(designID: id, kind: .original, maxPixelSize: 3072), priority: .normal, completion: { [weak self] image in
            if let image { self?.state.original = image }
        }) {
            tokens.append(token)
        }
    }

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
        let favorite = design.isFavorite
        if favorite != shownFavorite, let image = UIImage(systemName: favorite ? "heart.fill" : "heart") {
            if shownFavorite == nil {
                favoriteItem.image = image
            } else {
                favoriteItem.setSymbolImage(image, contentTransition: .replace)
                favoriteItem.playSymbolEffect(.bounce)
            }
            shownFavorite = favorite
        }
        favoriteItem.accessibilityLabel = favorite ? "Unfavorite" : "Favorite"
        let showingOriginal = state.showingOriginal
        if showingOriginal != shownOriginal, let image = UIImage(systemName: showingOriginal ? "square.split.2x1.fill" : "square.split.2x1") {
            if shownOriginal == nil { compareItem.image = image } else { compareItem.setSymbolImage(image, contentTransition: .replace) }
            shownOriginal = showingOriginal
        }
        compareItem.isEnabled = state.original != nil
        compareItem.accessibilityLabel = showingOriginal ? "Show design" : "Show original"
    }

    private func share() {
        guard !isTornDown, !design.isDeleted else { return }
        let image = design.resultImageData.flatMap { UIImage(data: $0) } ?? state.result
        let item = DesignShareItem(image: image, title: "\(design.styleTitle) \(design.subjectTitle)")
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.popoverPresentationController?.sourceItem = shareItem
        present(controller, animated: true)
    }

    private func makeTitleView() -> UIView {
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.text = "\(design.styleTitle) \(design.subjectTitle)"
        let subtitle = UILabel()
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabel
        subtitle.text = design.createdAt.formatted(date: .abbreviated, time: .shortened)
        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        return stack
    }

    private func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        observation += 1
        for token in tokens { DesignImagePipeline.shared.cancel(token) }
        tokens = []
        rootView = AnyView(Color.black.ignoresSafeArea())
    }
}

/// The viewer's content: the zoomable photo on white (black with the bars hidden) and the
/// "Original" badge while the original is shown.
struct PhotoViewerContent: View {
    let design: Design
    @Bindable var state: PhotoViewerState
    let zoomBox: ViewBox
    let onTap: () -> Void

    var body: some View {
        ZStack {
            (state.chromeHidden ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            PhotoZoomView(
                image: state.showingOriginal ? (state.original ?? state.result) : state.result,
                box: zoomBox,
                onTap: onTap,
                onPress: { pressed in if state.original != nil { state.showingOriginal = pressed } }
            )
            .ignoresSafeArea()
            .accessibilityLabel(state.showingOriginal ? "Original photo" : "\(design.styleTitle) \(design.subjectTitle) design")

            if state.showingOriginal {
                VStack {
                    Text("Original")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showingOriginal)
        .sensoryFeedback(.impact(weight: .medium), trigger: design.isFavorite)
        .sensoryFeedback(.impact(weight: .light), trigger: state.showingOriginal)
    }
}
