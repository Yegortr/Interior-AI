import SwiftUI
import UIKit

/// The same building block Photos uses: a `UIScrollView` that zooms an image view.
/// - pinch up to 5× with native rubber-banding, double-tap to zoom in/out at the finger
/// - single tap (after double-tap fails) toggles the chrome
/// - press and hold reports `true`/`false` (used to show the original while held)
/// - at 1× the scroll view doesn't pan, so a vertical drag reaches the system zoom transition's
///   interactive swipe-down-to-close
struct PhotoZoomView: UIViewRepresentable {
    let image: UIImage
    /// Hands the scroll view to the viewer controller (zoom alignment, swipe-down at 1× only).
    var box: ViewBox? = nil
    var onTap: () -> Void = {}
    var onPress: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        box?.view = view
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.onTap = onTap
        view.onPress = onPress
        view.setImage(image)
        box?.view = view
    }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onTap: () -> Void = {}
    var onPress: (Bool) -> Void = { _ in }

    private let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        panGestureRecognizer.isEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.3
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isAtMinimumZoom: Bool { zoomScale <= minimumZoomScale + 0.01 }

    /// Where the picture is drawn, in `target`'s coordinates.
    func imageFrame(in target: UIView) -> CGRect? {
        guard imageView.image != nil, imageView.bounds.width > 0, imageView.bounds.height > 0 else { return nil }
        return imageView.convert(imageView.bounds, to: target)
    }

    func setImage(_ image: UIImage) {
        guard image !== imageView.image else { return }
        let previous = imageView.image
        imageView.image = image
        // The same picture at another resolution (the full-size decode arriving) or an original of
        // the same shape: keep the frame and the user's zoom. Anything else re-fits at 1×.
        if let previous, previous.size.height > 0, image.size.height > 0, imageView.bounds.width > 0,
           abs(previous.size.width / previous.size.height - image.size.width / image.size.height) < 0.01 {
            return
        }
        setZoomScale(minimumZoomScale, animated: false)
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // layoutSubviews also runs while scrolling; only re-fit when the viewport size changes.
        guard bounds.size != lastBoundsSize else { return }
        lastBoundsSize = bounds.size
        setZoomScale(minimumZoomScale, animated: false)
        layoutImage()
    }

    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerImage()
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale + 0.01
    }

    // MARK: Gestures

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onTap()
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onPress(true)
        case .ended, .cancelled, .failed: onPress(false)
        default: break
        }
    }
}
