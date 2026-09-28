import SwiftUI

/// Immersive viewer presented over a clear full-screen cover.
///
/// Drag-to-dismiss choreography (driven by the downward drag distance):
/// - background blur/dim fades out proportionally
/// - the close button scales to 0 while its opacity fades 60% faster than the scale
/// - Before/After tabs slide up out of frame at full opacity — fading a material-backed control
///   forces an offscreen compositing pass that flickers, so only its offset animates.
struct FullscreenViewer: View {
    let after: UIImage
    let before: UIImage?
    let onClose: () -> Void

    @State private var showingBefore = false
    @State private var dragDistance: CGFloat = 0
    @State private var hasAppeared = false
    @State private var isClosing = false

    private static let progressDistance: CGFloat = 320

    private var progress: CGFloat { min(max(dragDistance / Self.progressDistance, 0), 1) }
    private var chromeScale: CGFloat { isClosing ? 0 : 1 - progress }
    /// Opacity leads the scale by 60%.
    private var chromeOpacity: CGFloat { isClosing ? 0 : 1 - min(1, progress * 1.6) }
    private var backgroundOpacity: CGFloat { hasAppeared && !isClosing ? 1 - progress : 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.82))
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                ZoomableImageView(
                    image: showingBefore ? (before ?? after) : after,
                    onDismissDrag: { distance in dragDistance = distance },
                    onDismissEnd: { shouldClose in
                        if shouldClose {
                            close()
                        } else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { dragDistance = 0 }
                        }
                    }
                )
                .ignoresSafeArea()
                .scaleEffect(hasAppeared ? 1 : 0.94)
                .opacity(hasAppeared ? 1 : 0)
            }
            .overlay(alignment: .top) {
                if before != nil {
                    beforeAfterTabs
                        .padding(.top, 8)
                        .offset(y: isClosing ? -(proxy.safeAreaInsets.top + 120) : -progress * (proxy.safeAreaInsets.top + 120))
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
                .scaleEffect(chromeScale)
                .opacity(chromeOpacity)
                .accessibilityLabel("Close")
            }
        }
        .statusBarHidden(hasAppeared && !isClosing)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { hasAppeared = true }
        }
    }

    private var beforeAfterTabs: some View {
        HStack(spacing: 0) {
            tab("After", isSelected: !showingBefore) { showingBefore = false }
            tab("Before", isSelected: showingBefore) { showingBefore = true }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .environment(\.colorScheme, .dark)
    }

    private func tab(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !isSelected else { return }
            Haptics.tap()
            withAnimation(Theme.snappy) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func close() {
        guard !isClosing else { return }
        withAnimation(.easeIn(duration: 0.24)) { isClosing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { onClose() }
    }
}
