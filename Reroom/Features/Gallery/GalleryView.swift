import SwiftData
import SwiftUI

/// Home: a Photos-style grid of designs. Creating starts from the "+" menu (or the empty state),
/// filters and layout live in a toolbar menu, settings in a sheet.
struct GalleryView: View {
    @Query(sort: \Design.createdAt, order: .reverse) private var designs: [Design]
    @Environment(GenerationCoordinator.self) private var coordinator
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("gallery.columnCount") private var columnCount = 2

    @State private var path: [Design] = []
    @State private var filter: Filter = .all
    @State private var creating: DesignKind?
    @State private var showSettings = false
    @State private var designToDelete: Design?
    @Namespace private var zoom

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Designs", rooms = "Rooms", gardens = "Gardens", favorites = "Favorites"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .rooms: "sofa"
            case .gardens: "leaf"
            case .favorites: "heart"
            }
        }
    }

    private var visible: [Design] {
        switch filter {
        case .all: designs
        case .rooms: designs.filter { $0.kind == .interior }
        case .gardens: designs.filter { $0.kind == .garden }
        case .favorites: designs.filter(\.isFavorite)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visible.isEmpty {
                    emptyState
                } else {
                    DesignGrid(
                        designs: visible,
                        columnCount: $columnCount,
                        coordinatorEnvironment: coordinator,
                        zoomNamespace: zoom,
                        onSelect: { path.append($0) },
                        onDelete: { designToDelete = $0 }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(filter == .all ? "Reroom" : filter.rawValue)
            .toolbar { toolbar }
            // Pushed screens own a bottom bar; make sure it never lingers on the grid after going back.
            .toolbar(.hidden, for: .bottomBar)
            .navigationDestination(for: Design.self) { design in
                DesignDetailView(design: design)
                    .navigationTransition(.zoom(sourceID: design.id, in: zoom))
            }
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
            .confirmationDialog(
                "Delete this design?",
                isPresented: Binding(get: { designToDelete != nil }, set: { if !$0 { designToDelete = nil } }),
                titleVisibility: .visible,
                presenting: designToDelete
            ) { design in
                Button("Delete Design", role: .destructive) {
                    withAnimation(.smooth) { coordinator.delete(design) }
                    designToDelete = nil
                }
            } message: { _ in
                Text("It will be removed from all your devices.")
            }
            .sensoryFeedback(.selection, trigger: filter)
            .sensoryFeedback(.selection, trigger: columnCount)
            // A new design appearing = a generation just started.
            .sensoryFeedback(.success, trigger: designs.count) { old, new in new > old }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Show", selection: $filter.animation(.smooth)) {
                    ForEach(Filter.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                Section("View As") {
                    Picker("View As", selection: $columnCount.animation(.smooth)) {
                        Label("List", systemImage: "rectangle.grid.1x2").tag(1)
                        Label("Large Grid", systemImage: "square.grid.2x2").tag(2)
                        Label("Grid", systemImage: "square.grid.3x3").tag(3)
                        Label("Small Grid", systemImage: "square.grid.4x3.fill").tag(4)
                    }
                }
                Divider()
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: filter == .all ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Options")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { creating = .interior } label: { Label("Redesign a Room", systemImage: "sofa") }
                Button { creating = .garden } label: { Label("Design a Garden", systemImage: "leaf") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New Design")
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if filter == .all {
            ContentUnavailableView {
                Label("Redesign Your Space", systemImage: "wand.and.sparkles")
                    .symbolEffect(.breathe)
            } description: {
                Text("Take a photo of a room or garden, pick a style, and see it transformed.")
            } actions: {
                Button { creating = .interior } label: {
                    Label("Redesign a Room", systemImage: "sofa")
                }
                .buttonStyle(.borderedProminent)
                Button { creating = .garden } label: {
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
                Button("Show All Designs") { filter = .all }
            }
        }
    }
}

extension DesignKind: Identifiable {
    var id: String { rawValue }
}
