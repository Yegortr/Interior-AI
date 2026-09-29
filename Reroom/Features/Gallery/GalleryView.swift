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
    // Pinch to zoom (Photos-style). The column count changes *during* the gesture when a
    // threshold is crossed; in between, the grid follows the fingers.
    @State private var pinchScale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var pinchAnchor: UnitPoint = .center
    @State private var isPinching = false

    static let columnRange = 1...4

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
                            .scaleEffect(pinchScale, anchor: pinchAnchor)
                            // Lifting two fingers must never "tap" the cell underneath.
                            .allowsHitTesting(!isPinching)
                    }
                    .scrollDisabled(isPinching)
                    .simultaneousGesture(pinchGesture)
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

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        if columnCount >= 2 {
            // Photos-style: edge to edge, hairline gutters.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                ForEach(visible) { cell($0, columns: columnCount) }
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

    // MARK: Pinch to zoom (like Photos)

    private static let layoutSpring = Animation.spring(duration: 0.32, bounce: 0)

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if !isPinching {
                    isPinching = true
                    pinchBase = 1
                    pinchAnchor = value.startAnchor
                }
                let relative = value.magnification / pinchBase

                // Crossing a threshold switches the layout right away, like Photos.
                if relative > 1.22, columnCount > Self.columnRange.lowerBound {
                    pinchBase = value.magnification
                    withAnimation(Self.layoutSpring) {
                        columnCount -= 1          // spread → bigger, fewer columns
                        pinchScale = 1
                    }
                    return
                }
                if relative < 0.82, columnCount < Self.columnRange.upperBound {
                    pinchBase = value.magnification
                    withAnimation(Self.layoutSpring) {
                        columnCount += 1          // pinch in → smaller, more columns
                        pinchScale = 1
                    }
                    return
                }

                // Follow the fingers; rubber-band at the ends of the range.
                let atLargest = columnCount == Self.columnRange.lowerBound && relative > 1
                let atSmallest = columnCount == Self.columnRange.upperBound && relative < 1
                let resistance: CGFloat = (atLargest || atSmallest) ? 0.15 : 0.6
                pinchScale = 1 + (relative - 1) * resistance
            }
            .onEnded { _ in
                withAnimation(Self.layoutSpring) { pinchScale = 1 }
                // Keep taps off until the fingers have fully left and the spring settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isPinching = false }
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
