import SwiftUI

/// Photos-style viewer. Presented with the system zoom transition (it grows out of the tapped
/// image and swipes down back into it). Tap toggles the bars; pinch/double-tap zoom via UIKit.
struct FullscreenViewer: View {
    let after: UIImage
    let before: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var showingBefore = false
    @State private var chromeVisible = true

    private enum Version: String, CaseIterable { case after = "After", before = "Before" }

    private var current: UIImage { showingBefore ? (before ?? after) : after }

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: current, onSingleTap: {
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
            })
            .ignoresSafeArea()
            .background(chromeVisible ? Color(.systemBackground) : .black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                if before != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Version", selection: Binding(
                            get: { showingBefore ? Version.before : .after },
                            set: { showingBefore = $0 == .before }
                        )) {
                            ForEach(Version.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: current), preview: SharePreview("Reroom design", image: Image(uiImage: current)))
                }
            }
            .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!chromeVisible)
            .sensoryFeedback(.selection, trigger: showingBefore)
        }
    }
}
