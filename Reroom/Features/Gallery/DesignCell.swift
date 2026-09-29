import Symbols
import UIKit

/// What a tile shows, copied out of the model once (never the image blobs). Equatable, so the
/// grid reconfigures a cell only when something visible changed.
struct DesignTileContent: Equatable {
    let id: UUID
    let status: DesignStatus
    let isFavorite: Bool
    let isGarden: Bool
    let title: String
    let errorMessage: String?
    let timerStart: Date
    let aspect: CGFloat

    init(_ design: Design) {
        id = design.id
        status = design.status
        isFavorite = design.isFavorite
        isGarden = design.kind == .garden
        title = "\(design.styleTitle) \(design.subjectTitle)"
        errorMessage = design.errorMessage
        timerStart = design.submittedAt ?? design.createdAt
        aspect = design.aspectRatio.value
    }

    var isRetryable: Bool { status == .failed || status == .stale }

    var statusTitle: String {
        switch status {
        case .submitting: "Uploading…"
        case .queued: "In queue…"
        case .generating: "Designing…"
        case .stale: "Taking longer than usual"
        case .failed: errorMessage ?? "Something went wrong"
        case .completed: ""
        }
    }
}

final class DesignCell: UICollectionViewCell {
    let tile = DesignTileView()
    /// The design this cell shows right now — what a tap on it opens.
    var designID: UUID? { tile.content?.id }

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.frame = contentView.bounds
        tile.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(tile)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Frames come from the layout: no Auto Layout sizing pass per cell.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    /// Pressed state, like the old plain-button dim. UIKit clears it before `didSelectItemAt`,
    /// so the zoom never starts from a dimmed tile.
    override var isHighlighted: Bool {
        didSet { tile.alpha = isHighlighted ? 0.8 : 1 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.prepareForReuse()
    }

    func configure(_ content: DesignTileContent, mode: GalleryMetrics.Mode, image: DesignImageRequest, onRetry: @escaping () -> Void) {
        tile.configure(content, cornerRadius: mode == .grid ? 0 : 12, compact: mode == .grid, image: image, onRetry: onRetry)
        accessibilityLabel = content.title
        accessibilityValue = content.status == .completed ? nil : content.statusTitle
        accessibilityCustomActions = content.isRetryable
            ? [UIAccessibilityCustomAction(name: "Try Again") { _ in onRetry(); return true }]
            : nil
    }
}

/// A design's picture with Photos-style glyphs, or its pending state over the blurred original.
/// Used by grid cells and the context-menu preview. Plain UIKit: nothing re-renders on scroll.
final class DesignTileView: UIView {
    private(set) var content: DesignTileContent?

    private let photoView = UIImageView()
    private let heart = UIImageView()
    private let leaf = UIImageView()
    private var showsHeart = false
    private var showsLeaf = false
    private var pending: PendingTileView?
    /// A design that just completed: its pending layer stays over the (blurred) original until
    /// the result is drawn, so the unblurred small original never shows.
    private var retiringPending: PendingTileView?
    private var imageKey: String?
    private var imageKind: DesignImageKind?
    private var imageToken: DesignImagePipeline.Token?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        addSubview(photoView)
        let symbol = UIImage.SymbolConfiguration(textStyle: .footnote)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        heart.image = UIImage(systemName: "heart.fill", withConfiguration: symbol)
        leaf.image = UIImage(systemName: "leaf.fill", withConfiguration: symbol)
        for glyph in [heart, leaf] {
            glyph.tintColor = .white
            glyph.alpha = 0
            // Same soft shadow as before, rasterized once: no offscreen pass while scrolling.
            glyph.layer.shadowColor = UIColor.black.cgColor
            glyph.layer.shadowOpacity = 0.5
            glyph.layer.shadowRadius = 2
            glyph.layer.shadowOffset = .zero
            glyph.layer.shouldRasterize = true
            addSubview(glyph)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        photoView.frame = bounds
        pending?.frame = bounds
        retiringPending?.frame = bounds
        layoutGlyphs()
    }

    private func layoutGlyphs() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        var visible: [UIImageView] = []
        if showsHeart { visible.append(heart) }
        if showsLeaf { visible.append(leaf) }
        let rowHeight = visible.map { $0.intrinsicContentSize.height }.max() ?? 0
        var x: CGFloat = 8
        for glyph in visible {
            let size = glyph.intrinsicContentSize
            glyph.frame = CGRect(x: x, y: bounds.height - 8 - (rowHeight + size.height) / 2, width: size.width, height: size.height)
            glyph.layer.rasterizationScale = scale
            x += size.width + 6
        }
    }

    func prepareForReuse() {
        DesignImagePipeline.shared.cancel(imageToken)
        imageToken = nil
        imageKey = nil
        imageKind = nil
        photoView.image = nil
        content = nil
        alpha = 1
        retiringPending?.removeFromSuperview()
        retiringPending = nil
    }

    func configure(_ new: DesignTileContent, cornerRadius: CGFloat, compact: Bool, image request: DesignImageRequest, onRetry: @escaping () -> Void) {
        let old = content
        let sameDesign = old?.id == new.id
        content = new
        layer.cornerRadius = cornerRadius
        // Under the picture: its own average colour once known, so a miss never flashes light.
        backgroundColor = DesignImagePipeline.shared.averageColor(designID: new.id, kind: request.kind) ?? .secondarySystemFill

        // Glyphs: finished designs only; favourite / completion changes fade.
        let completed = new.status == .completed
        showsHeart = completed && new.isFavorite
        showsLeaf = completed && new.isGarden
        let heartAlpha: CGFloat = showsHeart ? 1 : 0
        let leafAlpha: CGFloat = showsLeaf ? 1 : 0
        layoutGlyphs()
        if sameDesign, old?.isFavorite != new.isFavorite || old?.status != new.status {
            UIView.animate(withDuration: 0.25) {
                self.heart.alpha = heartAlpha
                self.leaf.alpha = leafAlpha
            }
        } else {
            heart.alpha = heartAlpha
            leaf.alpha = leafAlpha
        }

        // Pending layer.
        if !sameDesign, let retiringPending {
            self.retiringPending = nil
            retiringPending.removeFromSuperview()
        }
        if completed {
            if let pending {
                self.pending = nil
                if sameDesign {
                    retiringPending = pending          // fades once the result is drawn
                    bringSubviewToFront(pending)       // over the glyphs until then
                } else {
                    pending.removeFromSuperview()
                }
            }
        } else {
            if pending == nil, let retiringPending {    // back to pending before it faded
                self.retiringPending = nil
                retiringPending.alpha = 1
                insertSubview(retiringPending, aboveSubview: photoView)
                pending = retiringPending
            }
            let view = pending ?? makePendingView()
            view.configure(new, previous: sameDesign ? old : nil, compact: compact, onRetry: onRetry)
        }

        setImage(request, sameDesign: sameDesign)
        // Nothing left to wait for (drawn from memory, or the same request already settled).
        if imageToken == nil { retirePending() }
    }

    /// Fades out the pending layer of a design that has completed.
    private func retirePending() {
        guard let retiring = retiringPending else { return }
        retiringPending = nil
        guard window != nil else {
            retiring.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            retiring.alpha = 0
        }, completion: { _ in
            retiring.removeFromSuperview()
        })
    }

    func updateTimer() {
        pending?.updateTimer()
    }

    private func makePendingView() -> PendingTileView {
        let view = PendingTileView(frame: bounds)
        insertSubview(view, aboveSubview: photoView)
        pending = view
        return view
    }

    private func setImage(_ request: DesignImageRequest, sameDesign: Bool) {
        guard request.key != imageKey else { return }
        let pipeline = DesignImagePipeline.shared
        pipeline.cancel(imageToken)
        imageToken = nil
        imageKey = request.key
        let kindChanges = imageKind != nil && imageKind != request.kind
        if let hit = pipeline.cachedImage(request) {
            show(hit, kind: request.kind, fade: sameDesign && kindChanges)
            return
        }
        if let placeholder = pipeline.bestCachedImage(designID: request.designID, kind: request.kind) {
            show(placeholder, kind: request.kind, fade: sameDesign && kindChanges)
        } else if !sameDesign || (kindChanges && retiringPending == nil) {
            // Another design's picture, or the tiny original only ever meant to be seen under
            // the material: never left on show (the average colour / fill shows until it lands).
            photoView.image = nil
            imageKind = nil
        }
        imageToken = pipeline.load(request, priority: .high) { [weak self] image in
            // The cell may have been reused meanwhile: only the request it wants now may land.
            guard let self, self.imageKey == request.key else { return }
            self.imageToken = nil
            guard let image else {
                self.imageKey = nil        // retried on the next configure
                self.retirePending()
                return
            }
            self.show(image, kind: request.kind, fade: self.photoView.image == nil || self.imageKind != request.kind)
        }
    }

    private func show(_ image: UIImage, kind: DesignImageKind, fade: Bool) {
        imageKind = kind
        if kind == .result { retirePending() }
        guard fade, window != nil else {
            photoView.image = image
            return
        }
        UIView.transition(with: photoView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.photoView.image = image
        }
    }
}

/// Animated status symbol, title, elapsed time and Try Again on a material over the original.
final class PendingTileView: UIView {
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let stack = UIStackView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let timerLabel = UILabel()
    private let retryButton = UIButton(configuration: .borderedProminent())
    private var onRetry: () -> Void = {}
    private var iconState: String?
    private var isCompact: Bool?
    private var timerStart = Date()

    override init(frame: CGRect) {
        super.init(frame: frame)
        material.frame = bounds
        material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(material)
        let content = material.contentView
        // Cells pass under the bars: never let the safe area change the padding mid-scroll.
        content.insetsLayoutMarginsFromSafeArea = false
        content.preservesSuperviewLayoutMargins = false

        stack.axis = .vertical
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, titleLabel, timerLabel, retryButton] as [UIView] {
            stack.addArrangedSubview(view)
        }
        content.addSubview(stack)
        let centerY = stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        centerY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerY,
            stack.leadingAnchor.constraint(equalTo: content.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.layoutMarginsGuide.bottomAnchor),
        ])

        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true
        timerLabel.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textColor = .secondaryLabel

        var button = UIButton.Configuration.borderedProminent()
        button.title = "Try Again"
        button.image = UIImage(systemName: "arrow.clockwise")
        button.imagePadding = 4
        button.cornerStyle = .capsule
        retryButton.configuration = button
        // A UIControl: its taps never select the cell (no nested-button ambiguity).
        retryButton.addAction(UIAction(title: "Try Again") { [weak self] _ in
            self?.onRetry()
        }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `previous` is what this tile showed of the same design before (nil for another design).
    func configure(_ content: DesignTileContent, previous: DesignTileContent?, compact: Bool, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        if isCompact != compact {
            isCompact = compact
            stack.spacing = compact ? 8 : 12
            let margin: CGFloat = compact ? 10 : 20
            material.contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: margin, leading: margin, bottom: margin, trailing: margin)
            titleLabel.font = compact
                ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
                : UIFont.preferredFont(forTextStyle: .headline)
            titleLabel.numberOfLines = compact ? 3 : 4
            retryButton.configuration?.buttonSize = compact ? .small : .medium
            iconState = nil
        }
        titleLabel.text = content.statusTitle
        timerLabel.isHidden = !content.status.isInProgress
        retryButton.isHidden = !content.isRetryable
        timerStart = content.timerStart
        updateTimer()
        let state = "\(content.status.rawValue)-\(content.isGarden)"
        if state != iconState {
            iconState = state
            applyIcon(content, compact: compact)
        } else if content.status == .failed, let previous, previous.errorMessage != content.errorMessage {
            icon.playSymbolEffect(.bounce)          // as `.symbolEffect(.bounce, value: errorMessage)`
        }
    }

    /// Same text as SwiftUI's `Text(date, style: .timer)`: 0:42, 12:05, 1:02:03.
    func updateTimer() {
        guard !timerLabel.isHidden else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(timerStart)))
        timerLabel.text = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func applyIcon(_ content: DesignTileContent, compact: Bool) {
        icon.removeAllSymbolEffects()
        let size = UIImage.SymbolConfiguration(textStyle: compact ? .title2 : .largeTitle)
        let multicolor = size.applying(UIImage.SymbolConfiguration.preferringMulticolor())
        switch content.status {
        case .submitting:
            icon.image = UIImage(systemName: "icloud.and.arrow.up", withConfiguration: size)
            icon.runSymbolEffect(.pulse)
        case .queued:
            icon.image = UIImage(systemName: "hourglass", withConfiguration: size)
            icon.runSymbolEffect(.rotate)
        case .generating:
            icon.image = UIImage(systemName: content.isGarden ? "leaf.fill" : "wand.and.sparkles", withConfiguration: size)
            icon.runSymbolEffect(.breathe)
        case .stale:
            icon.image = UIImage(systemName: "clock.badge.exclamationmark", withConfiguration: multicolor)
            icon.runSymbolEffect(.pulse)
        case .failed:
            icon.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: multicolor)
        case .completed:
            icon.image = nil
        }
        icon.isHidden = icon.image == nil
    }
}

extension UIImageView {
    /// Runs `effect` until removed. The generic constraint picks UIKit's indefinite overload even
    /// for effects that are also discrete (several are, since iOS 18).
    func runSymbolEffect<Effect: IndefiniteSymbolEffect & SymbolEffect>(_ effect: Effect) {
        addSymbolEffect(effect)
    }

    /// Plays `effect` once (the discrete overload, for the same reason).
    func playSymbolEffect<Effect: DiscreteSymbolEffect & SymbolEffect>(_ effect: Effect) {
        addSymbolEffect(effect)
    }
}
