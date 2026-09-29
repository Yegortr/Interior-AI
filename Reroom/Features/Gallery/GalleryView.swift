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
        if columnCount == 2 {
            // Photos-style: edge to edge, hairline gutters.
            // Deliberately NOT lazy: lazy containers recreate cells when data changes (e.g. while
            // a generation is being polled), and a recreated cell mid-navigation makes the zoom
            // transition lose its source and fly to/from the centre of the screen.
            ColumnsLayout(columns: 2, spacing: 2) {
                ForEach(visible) { cell($0, columns: 2) }
            }
            .animation(.smooth, value: visible.map(\.id))
        } else {
            VStack(spacing: 16) {
                ForEach(visible) { cell($0, columns: 1) }
            }
            .padding(.horizontal)
            .animation(.smooth, value: visible.map(\.id))
        }
    }

    private func cell(_ design: Design, columns: Int) -> some View {
        NavigationLink(value: design) {
            DesignCard(design: design, columns: columns, zoomNamespace: zoom)
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

/// A plain (non-lazy) column grid. Unlike Grid rows, every cell keeps its own identity when
/// designs are inserted or removed, so zoom transition sources are never recreated.
struct ColumnsLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    private func columnWidth(for width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let proposal = ProposedViewSize(width: columnWidth(for: width), height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(proposal).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let heights = rowHeights(width: width, subviews: subviews)
        let height = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellWidth = columnWidth(for: bounds.width)
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (cellWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cellWidth, height: height)
                )
            }
            y += height + spacing
        }
    }
}
