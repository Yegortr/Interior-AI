import SwiftData
import SwiftUI

struct GalleryView: View {
    @Query(sort: \Design.createdAt, order: .reverse) private var designs: [Design]
    @Environment(GenerationCoordinator.self) private var coordinator

    @AppStorage("gallery.columnCount") private var columnCount = 2
    @State private var filter: Filter = .all
    @State private var creating: DesignKind?
    @State private var showSettings = false
    @State private var designToDelete: Design?
    @Namespace private var zoom

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", rooms = "Rooms", gardens = "Gardens", favorites = "Favorites"
        var id: String { rawValue }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        StartCard(kind: .interior) { start(.interior) }
                        StartCard(kind: .garden) { start(.garden) }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)

                    if !designs.isEmpty {
                        filterBar
                    }
                }
                .padding(.top, 4)

                if visible.isEmpty {
                    emptyState
                } else {
                    grid
                        .padding(.horizontal, columnCount == 2 ? Theme.gridSpacing : Theme.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Reroom")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Layout", selection: $columnCount.animation(Theme.spring)) {
                            Label("Grid", systemImage: "square.grid.2x2").tag(2)
                            Label("List", systemImage: "rectangle.grid.1x2").tag(1)
                        }
                    } label: {
                        Image(systemName: columnCount == 2 ? "square.grid.2x2" : "rectangle.grid.1x2")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("Layout")
                }
            }
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
            .sensoryFeedback(.selection, trigger: filter)
            .sensoryFeedback(.selection, trigger: columnCount)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog(
                "Delete this design?",
                isPresented: Binding(get: { designToDelete != nil }, set: { if !$0 { designToDelete = nil } }),
                titleVisibility: .visible,
                presenting: designToDelete
            ) { design in
                Button("Delete", role: .destructive) {
                    withAnimation(Theme.spring) { coordinator.delete(design) }
                    designToDelete = nil
                }
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if columnCount == 2 {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Theme.gridSpacing), GridItem(.flexible(), spacing: Theme.gridSpacing)],
                spacing: Theme.gridSpacing
            ) {
                ForEach(visible) { cell($0, columns: 2) }
            }
            .animation(Theme.spring, value: visible.map(\.id))
        } else {
            LazyVStack(spacing: 14) {
                ForEach(visible) { cell($0, columns: 1) }
            }
            .animation(Theme.spring, value: visible.map(\.id))
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
                    ? Label("Remove from Favorites", systemImage: "heart.slash")
                    : Label("Add to Favorites", systemImage: "heart")
            }
            if design.isRetryable {
                Button {
                    coordinator.retry(design)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                designToDelete = design
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var filterBar: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.horizontalPadding)
    }

    private func start(_ kind: DesignKind) {
        creating = kind
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(filter == .favorites ? "No favorites yet" : "Your designs appear here",
                  systemImage: filter == .favorites ? "heart" : "sparkles")
        } description: {
            Text(filter == .favorites
                 ? "Tap the heart on a design to keep it here."
                 : "Take a photo of a room or garden, pick a style, and see it transformed.")
        }
        .padding(.top, 24)
    }
}

extension DesignKind: Identifiable {
    var id: String { rawValue }
}

/// Big entry card on the home screen (Realtor.com / IKEA-style "add a photo to redesign").
private struct StartCard: View {
    let kind: DesignKind
    let action: () -> Void

    @State private var taps = 0

    private var colors: [Color] {
        kind == .interior
            ? [Color(hex: "#E9DFD3") ?? .brown, Color(hex: "#B08B6E") ?? .brown]
            : [Color(hex: "#DCEBD0") ?? .green, Color(hex: "#5E8C4A") ?? .green]
    }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: kind == .interior ? "sofa.fill" : "leaf.fill")
                    .symbolEffect(.bounce, value: taps)
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.white.opacity(0.25)))
                Spacer(minLength: 12)
                Text(kind == .interior ? "Redesign\na room" : "Design\na garden")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Label("Add photo", systemImage: "camera.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.25)))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(kind == .interior ? "Redesign a room" : "Design a garden")
    }
}
