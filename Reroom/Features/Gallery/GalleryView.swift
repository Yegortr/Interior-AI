import SwiftData
import SwiftUI

struct GalleryView: View {
    @Query(sort: \Design.createdAt, order: .reverse) private var designs: [Design]
    @Environment(GenerationCoordinator.self) private var coordinator

    @AppStorage("gallery.columnCount") private var columnCount = 2
    @State private var favoritesOnly = false
    @State private var showCreate = false
    @State private var showSettings = false
    @State private var designToDelete: Design?

    private var visible: [Design] {
        favoritesOnly ? designs.filter(\.isFavorite) : designs
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if visible.isEmpty {
                    emptyState
                } else {
                    grid
                        .padding(.horizontal, columnCount == 2 ? Theme.gridSpacing : Theme.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(favoritesOnly ? "Favorites" : "Reroom")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) { favoritesOnly.toggle() }
                    } label: {
                        Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(favoritesOnly ? "Show all designs" : "Show favorites")
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) { columnCount = columnCount == 2 ? 1 : 2 }
                    } label: {
                        Image(systemName: columnCount == 2 ? "rectangle.grid.1x2" : "square.grid.2x2")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(columnCount == 2 ? "One column" : "Two columns")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.tap()
                    showCreate = true
                } label: {
                    Label("New Design", systemImage: "plus")
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 8)
            }
            .navigationDestination(for: Design.self) { design in
                DesignDetailView(design: design)
            }
            .fullScreenCover(isPresented: $showCreate) {
                CreateFlowView()
            }
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
        }
        .buttonStyle(.pressable)
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        .contextMenu {
            Button {
                Haptics.impact()
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label(favoritesOnly ? "No favorites yet" : "Redesign your first room",
                  systemImage: favoritesOnly ? "heart" : "sparkles")
        } description: {
            Text(favoritesOnly
                 ? "Tap the heart on a design to keep it here."
                 : "Take a photo of a room, pick a style, and see it transformed.")
        }
        .padding(.top, 80)
    }
}
