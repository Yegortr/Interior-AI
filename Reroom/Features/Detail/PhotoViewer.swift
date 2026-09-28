import SwiftUI

/// Full-screen image viewer that behaves like a photo in Photos:
/// - pushed with the system zoom transition out of the tapped image; swipe down shrinks it back,
///   edge-swipe goes back
/// - `UIScrollView` zoom: pinch up to 5×, double-tap to zoom at the finger
/// - tap hides the bars and the background turns black
/// - press and hold (or the compare button) shows the original photo
struct PhotoViewer: View {
    let design: Design
    let result: UIImage
    let original: UIImage?

    @State private var chromeHidden = false
    @State private var showingOriginal = false

    var body: some View {
        ZStack {
            (chromeHidden ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            PhotoZoomView(
                image: showingOriginal ? (original ?? result) : result,
                onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                onPress: { pressed in if original != nil { showingOriginal = pressed } }
            )
            .ignoresSafeArea()
            .accessibilityLabel(showingOriginal ? "Original photo" : "\(design.styleTitle) \(design.subjectTitle) design")

            if showingOriginal {
                VStack {
                    Text("Original")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showingOriginal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("\(design.styleTitle) \(design.subjectTitle)").font(.headline)
                    Text(design.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(
                    item: Image(uiImage: result),
                    preview: SharePreview("\(design.styleTitle) \(design.subjectTitle)", image: Image(uiImage: result))
                )
                Spacer()
                Button {
                    design.isFavorite.toggle()
                } label: {
                    Image(systemName: design.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: design.isFavorite)
                }
                .accessibilityLabel(design.isFavorite ? "Unfavorite" : "Favorite")
                Spacer()
                Button {
                    showingOriginal.toggle()
                } label: {
                    Image(systemName: showingOriginal ? "square.split.2x1.fill" : "square.split.2x1")
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(original == nil)
                .accessibilityLabel(showingOriginal ? "Show design" : "Show original")
            }
        }
        .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .statusBarHidden(chromeHidden)
        .sensoryFeedback(.impact(weight: .medium), trigger: design.isFavorite)
        .sensoryFeedback(.impact(weight: .light), trigger: showingOriginal)
    }
}
