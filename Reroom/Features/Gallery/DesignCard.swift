import SwiftUI

/// Gallery cell. In two columns every cell — finished or not — is a fixed 3:4 crop so the grid
/// stays aligned; in one column it uses the design's own ratio, so a placeholder already has
/// the exact shape of the image that will replace it (no layout shift).
struct DesignCard: View {
    let design: Design
    let columns: Int

    @Environment(GenerationCoordinator.self) private var coordinator

    private var isCompact: Bool { columns == 2 }
    private var ratio: CGFloat { isCompact ? AspectRatio.gridCard.value : design.aspectRatio.value }

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
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if design.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if design.status == .completed, !isCompact {
                    Text("\(design.style.title) · \(design.roomType.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(10)
                }
            }
            .animation(Theme.spring, value: design.statusRaw)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(design.style.title) \(design.roomType.title)")
    }

    private var pending: some View {
        ZStack {
            DesignImage(design: design, kind: .original, maxPixelSize: 400)
                .blur(radius: 14)
                .opacity(0.45)
            Rectangle().fill(Theme.placeholderGradient)
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(design.submittedAt ?? design.createdAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if design.isRetryable {
                Button {
                    Haptics.tap()
                    coordinator.retry(design)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(compact ? .small : .regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch design.status {
        case .submitting, .queued, .generating:
            ProgressView().controlSize(compact ? .regular : .large)
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(compact ? .title3 : .largeTitle)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(compact ? .title3 : .largeTitle)
                .foregroundStyle(.red)
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

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
