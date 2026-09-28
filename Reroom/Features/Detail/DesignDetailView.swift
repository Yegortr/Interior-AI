import SwiftUI

/// Photos-style viewer — the design fills the screen.
/// - opened from the grid with the system zoom transition; swipe down to go back
/// - tap hides the bars (background turns black), pinch / double-tap to zoom
/// - press and hold shows the original photo, like comparing edits in Photos
/// - bottom bar: Share (incl. Save Image), Favorite, Compare, Info, Delete; "Edit" = Make Changes
struct DesignDetailView: View {
    let design: Design

    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var result: UIImage?
    @State private var original: UIImage?
    @State private var chromeHidden = false
    @State private var showingOriginal = false
    @State private var showInfo = false
    @State private var showMakeChanges = false
    @State private var confirmDelete = false

    private var isCompleted: Bool { design.status == .completed }

    private var displayed: UIImage? {
        showingOriginal ? (original ?? result) : result
    }

    var body: some View {
        ZStack {
            (chromeHidden ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            if isCompleted, let displayed {
                PhotoZoomView(
                    image: displayed,
                    onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                    onPress: { pressed in if original != nil { showingOriginal = pressed } }
                )
                .ignoresSafeArea()
                .accessibilityLabel(showingOriginal ? "Original photo" : "\(design.styleTitle) \(design.subjectTitle) design")
            } else {
                pending
            }

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
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showingOriginal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .statusBarHidden(chromeHidden)
        .sheet(isPresented: $showInfo) {
            DesignInfoSheet(design: design)
        }
        .sheet(isPresented: $showMakeChanges) {
            MakeChangesSheet(design: design) { dismiss() }
        }
        .confirmationDialog("Delete this design?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Design", role: .destructive) {
                dismiss()
                // Delete after the pop animation so this screen never reads a deleted model.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { coordinator.delete(design) }
            }
        } message: {
            Text("It will be removed from all your devices.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: design.isFavorite)
        .sensoryFeedback(.impact(weight: .light), trigger: showingOriginal)
        .task(id: design.statusRaw) { await loadImages() }
    }

    // MARK: Pending

    private var pending: some View {
        ZStack {
            if let original {
                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 20)
                    .opacity(0.5)
                    .ignoresSafeArea()
            }
            PendingStatusView(design: design, compact: false)
                .padding(32)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("\(design.styleTitle) \(design.subjectTitle)")
                    .font(.headline)
                Text(design.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isCompleted {
                Button("Edit") { showMakeChanges = true }
            } else if design.isRetryable {
                Button("Retry") { coordinator.retry(design) }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if let result, isCompleted {
                ShareLink(
                    item: Image(uiImage: result),
                    preview: SharePreview("\(design.styleTitle) \(design.subjectTitle)", image: Image(uiImage: result))
                )
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                design.isFavorite.toggle()
            } label: {
                Image(systemName: design.isFavorite ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: design.isFavorite)
            }
            .disabled(!isCompleted)
            .accessibilityLabel(design.isFavorite ? "Unfavorite" : "Favorite")
            Spacer()
            Button {
                showingOriginal.toggle()
            } label: {
                Image(systemName: showingOriginal ? "square.split.2x1.fill" : "square.split.2x1")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!isCompleted || original == nil)
            .accessibilityLabel(showingOriginal ? "Show design" : "Show original")
            Spacer()
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("Info")
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete")
        }
    }

    // MARK: Images

    private func loadImages() async {
        if let data = design.originalImageData {
            original = await LocalImageCache.shared.image(key: "\(design.id)-original-full", data: data, maxPixelSize: 3072)
        }
        if let data = design.resultImageData {
            let loaded = await LocalImageCache.shared.image(key: "\(design.id)-result-full", data: data, maxPixelSize: 3072)
            withAnimation(.smooth) { result = loaded }
        }
    }
}

/// Photos-style Info panel: details, wishes and — for gardens — the regional plants.
struct DesignInfoSheet: View {
    let design: Design

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if design.kind == .garden {
                        LabeledContent("Space") { Label("Garden", systemImage: "leaf") }
                        if let place = design.locationName {
                            LabeledContent("Location") { Label(place, systemImage: "mappin.and.ellipse") }
                        }
                    } else {
                        LabeledContent("Room") { Label(design.roomType.title, systemImage: design.roomType.symbol) }
                    }
                    LabeledContent("Style", value: design.styleTitle)
                    LabeledContent("Created", value: design.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if design.isFavorite {
                        LabeledContent("Favorite") { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    }
                }

                if !design.notes.isEmpty {
                    Section(design.parentId == nil ? "Your Wishes" : "Requested Change") {
                        Text(design.notes)
                    }
                }

                if design.kind == .garden {
                    if let notes = design.designNotes, !notes.isEmpty {
                        Section("Design Notes") { Text(notes) }
                    }
                    let plants = design.plants
                    if plants.isEmpty {
                        if design.status.isInProgress {
                            Section("Plants") {
                                Label {
                                    Text("Choosing plants for \(design.locationName ?? "your climate")…")
                                        .foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: "leaf.fill").foregroundStyle(.green).symbolEffect(.breathe)
                                }
                            }
                        }
                    } else {
                        Section {
                            ForEach(plants) { plant in
                                NavigationLink(value: plant) { PlantRow(plant: plant) }
                            }
                        } header: {
                            Text("Plants")
                        } footer: {
                            if let place = design.locationName { Text("Picked to thrive in \(place).") }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Plant.self) { plant in
                PlantDetailView(plant: plant, locationName: design.locationName)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct MakeChangesSheet: View {
    let design: Design
    var onSubmitted: () -> Void = {}

    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var change = ""
    @FocusState private var focused: Bool

    private var ideas: [String] {
        design.kind == .garden
            ? ["Add a stone pathway", "More flowering plants", "Add warm string lights", "Replace lawn with gravel", "Add a bench"]
            : ["Make it brighter", "Swap the sofa for a green velvet one", "Add indoor plants", "Warmer wood tones", "Change wall color to sage"]
    }

    private var canApply: Bool { !change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should change?", text: $change, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } footer: {
                    Text("Only what you describe changes — the rest of the design stays the same.")
                }
                Section("Ideas") {
                    ForEach(ideas, id: \.self) { idea in
                        Button {
                            change = change.isEmpty ? idea : "\(change), \(idea.lowercased())"
                        } label: {
                            Label(idea, systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("Make Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        coordinator.makeChanges(from: design, change: change)
                                        dismiss()
                        onSubmitted()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canApply)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
