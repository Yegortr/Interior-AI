import SwiftUI

/// Gallery cell. In two columns every cell — finished or not — is a fixed 3:4 crop so the grid
/// stays aligned; in one column it uses the design's own ratio, so a placeholder already has
/// the exact shape of the image that will replace it (no layout shift).
struct DesignCard: View {
    let design: Design
    let columns: Int

    private var isCompact: Bool { columns == 2 }
    private var ratio: CGFloat { isCompact ? AspectRatio.gridCard.value : design.aspectRatio.value }
    private var cornerRadius: CGFloat { isCompact ? 0 : 12 }

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                if design.status == .completed {
                    DesignImage(design: design, kind: .result, maxPixelSize: isCompact ? 700 : 1400)
                } else {
                    pending
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                // Photos-style glyphs: small, white, shadowed — no chips.
                HStack(spacing: 6) {
                    if design.isFavorite { Image(systemName: "heart.fill") }
                    if design.kind == .garden { Image(systemName: "leaf.fill") }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .padding(8)
                .opacity(design.status == .completed ? 1 : 0)
            }
            .animation(.smooth, value: design.statusRaw)
            .animation(.smooth, value: design.isFavorite)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(design.styleTitle) \(design.subjectTitle)")
            .accessibilityAddTraits(.isButton)
    }

    private var pending: some View {
        ZStack {
            DesignImage(design: design, kind: .original, maxPixelSize: 400)
                .blur(radius: 14)
            Rectangle().fill(.ultraThinMaterial)
            PendingStatusView(design: design, compact: isCompact)
                .padding(isCompact ? 10 : 20)
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
