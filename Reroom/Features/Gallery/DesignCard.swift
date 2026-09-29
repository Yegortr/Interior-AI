import SwiftUI

/// Gallery cell. In two columns every cell — finished or not — is a fixed 3:4 crop so the grid
/// stays aligned; in one column it uses the design's own ratio, so a placeholder already has
/// the exact shape of the image that will replace it (no layout shift).
struct DesignCard: View {
    let design: Design
    let columns: Int
    /// When set, the card is the zoom source for the design's detail screen.
    var zoomNamespace: Namespace.ID?

    private var isCompact: Bool { columns == 2 }
    private var isCompleted: Bool { design.status == .completed }
    private var ratio: CGFloat { isCompact ? AspectRatio.gridCard.value : design.aspectRatio.value }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: isCompact ? 0 : 12, style: .continuous) }

    var body: some View {
        photo
            .zoomSource(id: design.id, in: zoomNamespace, shape: shape)
            // Everything that isn't a plain picture stays OUTSIDE the zoom source. A material,
            // a shadow or an animated symbol inside a source can keep SwiftUI from matching it,
            // and the zoom then falls back to growing from / shrinking into the screen centre.
            .overlay {
                ZStack {
                    if !isCompleted {
                        pending.transition(.opacity)
                    }
                }
                .animation(.smooth, value: isCompleted)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(design.styleTitle) \(design.subjectTitle)")
            .accessibilityAddTraits(.isButton)
    }

    /// The zoom source: the picture (the result, or the photo while it's being designed) and
    /// its badges, clipped — nothing else.
    private var photo: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                DesignImage(
                    design: design,
                    kind: isCompleted ? .result : .original,
                    maxPixelSize: isCompleted ? (isCompact ? 520 : 1200) : 400
                )
            }
            .overlay(alignment: .bottom) {
                if isCompleted { badges }
            }
            .clipShape(shape)
    }

    /// Photos-style glyphs: small and white over a soft scrim (a gradient, not a shadow).
    @ViewBuilder
    private var badges: some View {
        if design.isFavorite || design.kind == .garden {
            HStack(spacing: 6) {
                if design.isFavorite { Image(systemName: "heart.fill") }
                if design.kind == .garden { Image(systemName: "leaf.fill") }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .bottom, endPoint: .top)
            }
        }
    }

    /// Frosted photo with the status on top, laid over the source.
    private var pending: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            PendingStatusView(design: design, compact: isCompact)
                .padding(isCompact ? 10 : 20)
        }
        .clipShape(shape)
    }
}

private extension View {
    @ViewBuilder
    func zoomSource(id: UUID, in namespace: Namespace.ID?, shape: RoundedRectangle) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(shape)
            }
        } else {
            self
        }
    }
}

/// Status, elapsed time and retry for a design that isn't finished yet.
struct PendingStatusView: View {
    let design: Design
    let compact: Bool

    @Environment(GenerationCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            icon
            Text(title)
                .font(compact ? .footnote.weight(.semibold) : .headline)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 3 : 4)
            if design.status.isInProgress {
                // System-driven timer text: no manual ticking.
                Text(design.submittedAt ?? design.createdAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if design.isRetryable {
                Button {
                    coordinator.retry(design)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(compact ? .small : .regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Animated SF Symbols instead of spinners: each state has its own motion.
    @ViewBuilder
    private var icon: some View {
        let font: Font = compact ? .title2 : .largeTitle
        switch design.status {
        case .submitting:
            Image(systemName: "icloud.and.arrow.up")
                .font(font)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
        case .queued:
            Image(systemName: "hourglass")
                .font(font)
                .foregroundStyle(.tint)
                .symbolEffect(.rotate)
        case .generating:
            Image(systemName: design.kind == .garden ? "leaf.fill" : "wand.and.sparkles")
                .font(font)
                .foregroundStyle(.tint)
                .symbolEffect(.breathe)
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(font)
                .symbolRenderingMode(.multicolor)
                .symbolEffect(.pulse)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(font)
                .symbolRenderingMode(.multicolor)
                .symbolEffect(.bounce, value: design.errorMessage)
        case .completed:
            EmptyView()
        }
    }

    private var title: String {
        switch design.status {
        case .submitting: "Uploading…"
        case .queued: "In queue…"
        case .generating: "Designing…"
        case .stale: "Taking longer than usual"
        case .failed: design.errorMessage ?? "Something went wrong"
        case .completed: ""
        }
    }
}
