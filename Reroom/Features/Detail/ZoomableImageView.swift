import SwiftUI
import UIKit

/// UIKit-backed zoomable image:
/// - pinch to zoom up to 5× with native rubber-banding past the limits (`bouncesZoom`)
/// - double-tap toggles 2.5× zoom centred on the tap point
/// - optional drag-to-dismiss pan that only engages at 1× when the drag is mostly downward
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var dismissEnabled = true
    /// Starts zoomed to fill the view (used by the inline landscape preview).
    var fillsOnLoad = false
    /// Downward drag distance in points while dragging to dismiss.
    var onDismissDrag: ((CGFloat) -> Void)?
    /// `true` when the drag passed the threshold and the view is animating out.
    var onDismissEnd: ((Bool) -> Void)?

    func makeUIView(context: Context) -> ZoomableImageContainerView {
        ZoomableImageContainerView()
    }

    func updateUIView(_ view: ZoomableImageContainerView, context: Context) {
        view.dismissEnabled = dismissEnabled
        view.fillsOnLoad = fillsOnLoad
        view.onDismissDrag = onDismissDrag
        view.onDismissEnd = onDismissEnd
        view.setImage(image)
    }
}

final class ZoomableImageContainerView: UIView, UIScrollViewDelegate {
    static let maximumZoom: CGFloat = 5
    static let doubleTapZoom: CGFloat = 2.5
    static let dismissDistance: CGFloat = 120
    static let dismissVelocity: CGFloat = 900

    var dismissEnabled = true
    var fillsOnLoad = false
    var onDismissDrag: ((CGFloat) -> Void)?
    var onDismissEnd: ((Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    private var lastLaidOutSize: CGSize = .zero
    private let snapFeedback = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maximumZoom
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // UIView.gestureRecognizerShouldBegin (overridden below) gates this recognizer.
        addGestureRecognizer(dismissPan)
        scrollView.panGestureRecognizer.require(toFail: dismissPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Image

    func setImage(_ image: UIImage) {
        guard image !== imageView.image else { return }
        display(image, resetZoom: true)
    }

    private func display(_ image: UIImage, resetZoom: Bool) {
        imageView.image = image
        if resetZoom || scrollView.zoomScale <= scrollView.minimumZoomScale {
            scrollView.setZoomScale(1, animated: false)
            layoutImage()
            if fillsOnLoad { zoomToFill() }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size
        scrollView.setZoomScale(1, animated: false)
        layoutImage()
        if fillsOnLoad { zoomToFill() }
    }

    private func fittedSize(for image: UIImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let size = fittedSize(for: image)
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        centerContent()
    }

    private func zoomToFill() {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        let fill = max(bounds.width / imageView.bounds.width, bounds.height / imageView.bounds.height)
        let scale = min(max(fill, 1), Self.maximumZoom)
        scrollView.setZoomScale(scale, animated: false)
        let offset = CGPoint(
            x: max(0, (scrollView.contentSize.width - bounds.width) / 2),
            y: max(0, (scrollView.contentSize.height - bounds.height) / 2)
        )
        scrollView.setContentOffset(offset, animated: false)
    }

    /// Keeps the image centred while it's smaller than the viewport.
    private func centerContent() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    // MARK: Gestures

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale = Self.doubleTapZoom
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            scrollView.zoom(to: rect, animated: true)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === dismissPan else { return super.gestureRecognizerShouldBegin(recognizer) }
        guard dismissEnabled, scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
        let velocity = dismissPan.velocity(in: self)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        // Pulling back above the start point is resisted.
        let dy = translation.y > 0 ? translation.y : translation.y / 4
        let progress = min(max(dy / 320, 0), 1)

        switch recognizer.state {
        case .began:
            snapFeedback.prepare()
        case .changed:
            scrollView.transform = CGAffineTransform(translationX: translation.x * 0.35, y: dy)
                .scaledBy(x: 1 - progress * 0.25, y: 1 - progress * 0.25)
            onDismissDrag?(max(0, dy))
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: self).y
            let shouldDismiss = recognizer.state == .ended && (dy > Self.dismissDistance || velocity > Self.dismissVelocity)
            if shouldDismiss {
                snapFeedback.impactOccurred()
                onDismissEnd?(true)
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                    self.scrollView.transform = CGAffineTransform(translationX: translation.x * 0.35, y: self.bounds.height)
                        .scaledBy(x: 0.7, y: 0.7)
                    self.scrollView.alpha = 0
                }
            } else {
                onDismissEnd?(false)
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.scrollView.transform = .identity
                }
            }
        default:
            break
        }
    }
}
