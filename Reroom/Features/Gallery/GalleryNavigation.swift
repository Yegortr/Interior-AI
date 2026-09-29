import Observation
import SwiftData
import SwiftUI
import UIKit

/// Status-bar state UIKit screens hand to SwiftUI: only the window's root hosting controller
/// decides it, so the photo viewer asks through this.
@Observable
final class GalleryChrome {
    var statusBarHidden = false
}

/// The navigation spine: a UINavigationController whose root is the grid. Designs, plants and the
/// photo viewer are pushed on it, so Back, edge swipe and the zoom's swipe-down are native UIKit.
struct GalleryNavigation: UIViewControllerRepresentable {
    let designs: [Design]
    let generation: GenerationCoordinator
    let modelContext: ModelContext
    let chrome: GalleryChrome
    let onCreate: (DesignKind) -> Void
    let onSettings: () -> Void

    func makeCoordinator() -> GalleryRouter {
        GalleryRouter(generation: generation, modelContext: modelContext, chrome: chrome)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        DesignImagePipeline.shared.configure(container: modelContext.container, mainContext: modelContext)
        let router = context.coordinator
        let grid = GalleryGridController(router: router)
        let navigation = UINavigationController(rootViewController: grid)
        navigation.navigationBar.prefersLargeTitles = true
        navigation.delegate = router
        router.navigation = navigation
        router.grid = grid
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        let router = context.coordinator
        router.onCreate = onCreate
        router.onSettings = onSettings
        router.grid?.setDesigns(designs)
    }
}

/// Every push and pop of the gallery goes through here.
@MainActor
final class GalleryRouter: NSObject, UINavigationControllerDelegate {
    let generation: GenerationCoordinator
    let modelContext: ModelContext
    let chrome: GalleryChrome
    var onCreate: (DesignKind) -> Void = { _ in }
    var onSettings: () -> Void = {}
    /// Not `navigationController`: that would clash with the delegate methods' parameter.
    weak var navigation: UINavigationController?
    weak var grid: GalleryGridController?
    /// A design screen built while the finger is still down (see `prepareDesign`).
    private var prepared: DesignDetailController?

    init(generation: GenerationCoordinator, modelContext: ModelContext, chrome: GalleryChrome) {
        self.generation = generation
        self.modelContext = modelContext
        self.chrome = chrome
        super.init()
    }

    /// SwiftUI hosted by UIKit doesn't inherit the app's environment: inject it.
    func host<Content: View>(_ content: Content) -> AnyView {
        AnyView(content.environment(generation).modelContext(modelContext))
    }

    func create(_ kind: DesignKind) { onCreate(kind) }
    func showSettings() { onSettings() }

    func setStatusBarHidden(_ hidden: Bool) {
        guard chrome.statusBarHidden != hidden else { return }
        withAnimation(.easeInOut(duration: 0.2)) { chrome.statusBarHidden = hidden }
    }

    // MARK: Grid → design (zoom)

    /// Builds and lays out the design screen on touch-down, so that on touch-up the zoom starts
    /// at once instead of first waiting for SwiftUI to build the page.
    func prepareDesign(_ design: Design) {
        guard prepared?.designID != design.id, let navigation, let grid,
              navigation.topViewController === grid, navigation.transitionCoordinator == nil,
              !design.isDeleted, design.modelContext != nil else { return }
        let detail = DesignDetailController(design: design, router: self)
        detail.loadViewIfNeeded()
        detail.view.frame = navigation.view.bounds
        detail.view.layoutIfNeeded()
        prepared = detail
    }

    /// The touch turned into a scroll: the prepared screen won't be opened.
    func discardPreparedDesign() {
        prepared = nil
    }

    func openDesign(_ design: Design, from grid: GalleryGridController) {
        guard let navigation, navigation.topViewController === grid else { return }
        // Whatever the previous design queued for the grid (Delete, Make Changes) runs now, so it
        // is never lost; the snapshot is frozen from the push on, so a delete / insert is safe.
        grid.runReturnActionsNow()
        guard !design.isDeleted, design.modelContext != nil else { return }
        let id = design.id
        let detail = prepared.flatMap { $0.designID == id ? $0 : nil } ?? DesignDetailController(design: design, router: self)
        prepared = nil
        let options = UIViewController.Transition.ZoomOptions()
        // Photos-style: line the page's picture up with the cell, cropped to the cell's shape, so
        // what shrinks into the cell is exactly the cell's picture — not the white list around it.
        options.alignmentRectProvider = { context in
            (context.zoomedViewController as? DesignDetailController)?.heroAlignmentRect(sourceSize: context.sourceView.bounds.size) ?? .null
        }
        // Asked when opening AND when closing. Look the cell up by id every time (cells are
        // reused), and capture the grid strongly: a nil view is what makes UIKit fall back to
        // zooming from/into the centre of the screen.
        detail.preferredTransition = .zoom(options: options) { [weak detail] _ in
            let isClosing = detail.map { $0.navigationController?.topViewController !== $0 } ?? true
            return grid.zoomSourceView(for: id, scrollIntoView: isClosing)
        }
        navigation.pushViewController(detail, animated: true)
    }

    /// Back to the grid from `screen`: first let go of anything it presents (Make Changes sheet,
    /// a confirmation), then pop with the zoom back into the cell, then run `action` once the
    /// grid is on screen and the zoom has completely finished.
    func close(_ screen: UIViewController, then action: @escaping () -> Void) {
        screen.afterDismissingPresentations { [weak self] in
            guard let self, let navigation = self.navigation, let grid = self.grid else {
                action()
                return
            }
            grid.runWhenBack(from: screen, action)
            if navigation.topViewController === grid {
                grid.settle()
            } else {
                navigation.popToViewController(grid, animated: true)
            }
        }
    }

    /// `screen` is showing (again): a pop of it that was meant to run something was cancelled.
    func designScreenDidAppear(_ screen: UIViewController) {
        grid?.discardReturnActions(from: screen)
    }

    // MARK: Design → plant, design → photo viewer

    func openPlant(_ plant: Plant, locationName: String?) {
        guard let navigation, navigation.topViewController is DesignDetailController else { return }
        let page = SpineHostingController(rootView: host(PlantDetailView(plant: plant, locationName: locationName)))
        page.navigationItem.title = plant.name
        page.navigationItem.largeTitleDisplayMode = .always
        navigation.pushViewController(page, animated: true)
    }

    func openViewer(from detail: DesignDetailController, result: UIImage, original: UIImage?) {
        guard let navigation, navigation.topViewController === detail else { return }
        let viewer = PhotoViewerController(design: detail.design, result: result, original: original, router: self)
        let options = UIViewController.Transition.ZoomOptions()
        options.alignmentRectProvider = { context in
            (context.zoomedViewController as? PhotoViewerController)?.imageAlignmentRect(sourceSize: context.sourceView.bounds.size) ?? .null
        }
        // Zoomed in, a drag pans the photo; only at 1× does swipe-down close.
        options.interactiveDismissShouldBegin = { [weak viewer] _ in
            viewer?.isAtMinimumZoom ?? true
        }
        // Captures the detail strongly (the viewer is released when popped: no cycle).
        viewer.preferredTransition = .zoom(options: options) { _ in
            detail.heroImage.view ?? detail.heroAnchor.view
        }
        navigation.pushViewController(viewer, animated: true)
    }

    // MARK: Designs deleted elsewhere (another device)

    func designsWereDeleted(_ ids: Set<UUID>) {
        guard let navigation, let grid else { return }
        let affected = navigation.viewControllers.contains { controller in
            guard let detail = controller as? DesignDetailController else { return false }
            return ids.contains(detail.designID)
        }
        guard affected, let top = navigation.topViewController else { return }
        for controller in navigation.viewControllers {
            (controller as? DesignDetailController)?.designWasDeleted()
            (controller as? PhotoViewerController)?.designWasDeleted()
        }
        // The grid still shows the cell (frozen), so the zoom back lands; it leaves afterwards.
        top.afterDismissingPresentations {
            navigation.popToViewController(grid, animated: navigation.topViewController is DesignDetailController)
        }
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        grid?.settle()
    }
}

/// A SwiftUI screen pushed on the spine. UIKit owns its bars (set before the push, so nothing
/// pops in after the animation); subclasses say whether they want the toolbar.
class SpineHostingController: UIHostingController<AnyView> {
    var prefersToolbarVisible: Bool { false }
    var prefersNavigationBarHidden: Bool { false }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(prefersNavigationBarHidden, animated: animated)
        navigationController?.setToolbarHidden(!prefersToolbarVisible, animated: animated)
    }
}

extension UIViewController {
    /// Runs `work` once nothing is presented over this controller, dismissing whatever is.
    func afterDismissingPresentations(_ work: @escaping () -> Void) {
        guard let presented = presentedViewController else {
            work()
            return
        }
        let next: () -> Void = { [weak self] in
            if let self { self.afterDismissingPresentations(work) } else { work() }
        }
        if presented.isBeingDismissed {
            if let coordinator = presented.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: { _ in next() }) {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
        } else {
            dismiss(animated: true, completion: next)
        }
    }
}
