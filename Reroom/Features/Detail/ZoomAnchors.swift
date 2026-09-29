import SwiftUI
import UIKit

/// A weak handle on a UIKit view living inside SwiftUI content.
final class ViewBox {
    weak var view: UIView?
}

/// An empty UIKit view laid out exactly where it's placed; UIKit's zoom reads its frame.
struct ZoomAnchor: UIViewRepresentable {
    let box: ViewBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

/// The detail's picture as a real UIImageView, so the photo viewer can zoom out of it and back.
struct HeroImage: UIViewRepresentable {
    let image: UIImage?
    /// Shown until the picture is there (the picture's average colour when known).
    let placeholder: UIColor?
    let box: ViewBox

    func makeUIView(context: Context) -> HeroImageView {
        let view = HeroImageView()
        box.view = view
        return view
    }

    func updateUIView(_ view: HeroImageView, context: Context) {
        view.image = image
        view.backgroundColor = placeholder ?? .secondarySystemFill
        box.view = view
    }
}

/// No intrinsic size: fills whatever SwiftUI proposes (a UIImageView alone would size to its image).
final class HeroImageView: UIView {
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { if newValue !== imageView.image { imageView.image = newValue } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false          // the SwiftUI Button around it takes the tap
        clipsToBounds = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

extension CGRect {
    /// The largest rect of `aspect` (width / height) centred in this one: the part of a picture
    /// drawn here that an aspect-fill view of that shape shows. Zoom alignment rects are cropped
    /// to the source's shape, so both ends of the zoom scale uniformly and show the same pixels.
    func centeredCrop(aspect: CGFloat) -> CGRect {
        guard !isNull, aspect > 0, width > 0, height > 0 else { return self }
        if width / height > aspect {
            let croppedWidth = height * aspect
            return CGRect(x: midX - croppedWidth / 2, y: minY, width: croppedWidth, height: height)
        }
        let croppedHeight = width / aspect
        return CGRect(x: minX, y: midY - croppedHeight / 2, width: width, height: croppedHeight)
    }
}
