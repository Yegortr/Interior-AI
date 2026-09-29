import SwiftUI

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
