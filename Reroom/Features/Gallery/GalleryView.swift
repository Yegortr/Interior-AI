import SwiftData
import SwiftUI

/// Home. The UIKit spine (grid + pushes) fills the screen; the modal pieces that were SwiftUI
/// stay SwiftUI here, so flows, Settings and onboarding keep their environment untouched.
struct GalleryView: View {
    @Query(sort: \Design.createdAt, order: .reverse) private var designs: [Design]
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var creating: DesignKind?
    @State private var showSettings = false
    @State private var chrome = GalleryChrome()

    var body: some View {
        GalleryNavigation(
            designs: designs,
            generation: coordinator,
            modelContext: modelContext,
            chrome: chrome,
            onCreate: { creating = $0 },
            onSettings: { showSettings = true }
        )
        .ignoresSafeArea()
        .statusBarHidden(chrome.statusBarHidden)
        .fullScreenCover(item: $creating) { kind in
            switch kind {
            case .interior: CreateFlowView()
            case .garden: GardenFlowView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Binding(get: { !hasCompletedOnboarding }, set: { _ in })) {
            OnboardingView { hasCompletedOnboarding = true }
                .interactiveDismissDisabled()
        }
        // A new design appearing = a generation just started.
        .sensoryFeedback(.success, trigger: designs.count) { old, new in new > old }
    }
}

/// Hosted by the grid as its `contentUnavailableConfiguration`.
struct GalleryEmptyState: View {
    let filter: GalleryFilter
    let onCreate: (DesignKind) -> Void
    let onShowAll: () -> Void

    var body: some View {
        if filter == .all {
            ContentUnavailableView {
                Label("Redesign Your Space", systemImage: "wand.and.sparkles")
                    .symbolEffect(.breathe)
            } description: {
                Text("Take a photo of a room or garden, pick a style, and see it transformed.")
            } actions: {
                Button { onCreate(.interior) } label: {
                    Label("Redesign a Room", systemImage: "sofa")
                }
                .buttonStyle(.borderedProminent)
                Button { onCreate(.garden) } label: {
                    Label("Design a Garden", systemImage: "leaf")
                }
                .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView {
                Label("No \(filter.rawValue)", systemImage: filter.symbol)
            } description: {
                Text(filter == .favorites ? "Designs you favorite appear here." : "Nothing here yet.")
            } actions: {
                Button("Show All Designs", action: onShowAll)
            }
        }
    }
}

extension DesignKind: Identifiable {
    var id: String { rawValue }
}
