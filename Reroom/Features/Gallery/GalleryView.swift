import SwiftData
import SwiftUI

/// Home: a Photos-style grid of designs. Creating starts from the "+" menu (or the empty state),
/// filters and layout live in a toolbar menu, settings in a sheet.
struct GalleryView: View {
    @Query(sort: \Design.createdAt, order: .reverse) private var designs: [Design]
    @Environment(GenerationCoordinator.self) private var coordinator
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("gallery.columnCount") private var columnCount = 2

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
        NavigationStack {
            Group {
                if visible.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        grid
                    }
                }
            }
            .navigationTitle(filter == .all ? "Reroom" : filter.rawValue)
            .toolbar { toolbar }
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

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        if columnCount == 2 {
            // Photos-style: edge to edge, hairline gutters.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(visible) { cell($0, columns: 2) }
            }
            .animation(.smooth, value: visible.map(\.id))
        } else {
            LazyVStack(spacing: 16) {
                ForEach(visible) { cell($0, columns: 1) }
            }
            .padding(.horizontal)
            .animation(.smooth, value: visible.map(\.id))
        }
    }

    private func cell(_ design: Design, columns: Int) -> some View {
        NavigationLink(value: design) {
            DesignCard(design: design, columns: columns)
                .matchedTransitionSource(id: design.id, in: zoom)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                design.isFavorite.toggle()
            } label: {
                design.isFavorite
                    ? Label("Unfavorite", systemImage: "heart.slash")
                    : Label("Favorite", systemImage: "heart")
            }
            if design.isRetryable {
                Button {
                    coordinator.retry(design)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                designToDelete = design
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } preview: {
            DesignCard(design: design, columns: 1)
                .frame(width: 300)
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
                        Label("Grid", systemImage: "square.grid.2x2").tag(2)
                        Label("List", systemImage: "rectangle.grid.1x2").tag(1)
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
