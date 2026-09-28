import QuickLook
import SwiftUI

struct DesignDetailView: View {
    let design: Design

    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .design
    @State private var result: UIImage?
    @State private var original: UIImage?
    /// Quick Look: the system full-screen viewer used by Photos and Files.
    @State private var previewURL: URL?
    @State private var previewItems: [URL] = []
    @State private var showMakeChanges = false
    @State private var confirmDelete = false
    @State private var saveState: SaveState = .idle
    @State private var saveError: String?

    private enum Mode: String, CaseIterable { case design = "Design", compare = "Before & After" }
    private enum SaveState: Equatable { case idle, saving, saved }

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if design.status == .completed, original != nil {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 12)
                }
            }

            Section("Details") {
                if design.kind == .garden {
                    LabeledContent("Space") { Label("Garden", systemImage: "leaf") }
                    if let place = design.locationName {
                        LabeledContent("Location") { Label(place, systemImage: "mappin.and.ellipse") }
                    }
                } else {
                    LabeledContent("Room") { Label(design.roomType.title, systemImage: design.roomType.symbol) }
                }
                LabeledContent("Style", value: design.styleTitle)
                LabeledContent("Created") {
                    Text(design.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if !design.notes.isEmpty {
                Section(design.parentId == nil ? "Your Wishes" : "Requested Change") {
                    Text(design.notes)
                }
            }

            if design.kind == .garden {
                gardenSections
            }

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(design.styleTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Plant.self) { plant in
            PlantDetailView(plant: plant, locationName: design.locationName)
        }
        .toolbar { toolbar }
        .confirmationDialog("Delete this design?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Design", role: .destructive) {
                dismiss()
                // Delete after the pop animation so this screen never reads a deleted model.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { coordinator.delete(design) }
            }
        } message: {
            Text("It will be removed from all your devices.")
        }
        .sheet(isPresented: $showMakeChanges) {
            MakeChangesSheet(design: design) { dismiss() }
        }
        .quickLookPreview($previewURL, in: previewItems)
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.impact(weight: .medium), trigger: design.isFavorite)
        .sensoryFeedback(.success, trigger: saveState) { _, new in new == .saved }
        .task(id: design.statusRaw) { await loadImages() }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if design.status != .completed {
            Color.clear
                .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                .overlay {
                    ZStack {
                        DesignImage(design: design, kind: .original, maxPixelSize: 1200)
                            .blur(radius: 14)
                            .opacity(0.45)
                        Rectangle().fill(.ultraThinMaterial)
                        PendingStatusView(design: design, compact: false).padding(24)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if mode == .compare, let result, let original {
            BeforeAfterSlider(before: original, after: result, aspectRatio: design.aspectRatio.value)
                .transition(.opacity)
        } else {
            Button {
                openPreview()
            } label: {
                Color.clear
                    .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                    .overlay {
                        if let result {
                            Image(uiImage: result).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full screen")
            .transition(.opacity)
        }
    }

    // MARK: Garden

    @ViewBuilder
    private var gardenSections: some View {
        if let notes = design.designNotes, !notes.isEmpty {
            Section("Design Notes") {
                Text(notes)
            }
        }
        let plants = design.plants
        if plants.isEmpty {
            if design.status.isInProgress {
                Section("Plants") {
                    Label {
                        Text("Choosing plants for \(design.locationName ?? "your climate")…")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.breathe)
                    }
                }
            }
        } else {
            Section {
                ForEach(plants) { plant in
                    NavigationLink(value: plant) {
                        PlantRow(plant: plant)
                    }
                }
            } header: {
                Text("Plants")
            } footer: {
                if let place = design.locationName {
                    Text("Picked to thrive in \(place).")
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if design.isRetryable {
                    Button { coordinator.retry(design) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                }
                if design.resultImageData != nil {
                    Button { openPreview() } label: { Label("View Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        if design.status == .completed {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    design.isFavorite.toggle()
                } label: {
                    Image(systemName: design.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: design.isFavorite)
                }
                .tint(design.isFavorite ? .pink : nil)
                .accessibilityLabel(design.isFavorite ? "Unfavorite" : "Favorite")

                Spacer()

                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Image(systemName: saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: saveState == .saving)
                }
                .disabled(saveState == .saving)
                .accessibilityLabel("Save to Photos")

                Spacer()

                if let result {
                    ShareLink(item: Image(uiImage: result), preview: SharePreview("Reroom design", image: Image(uiImage: result)))
                }

                Spacer()

                Button {
                    showMakeChanges = true
                } label: {
                    Label("Make Changes", systemImage: "wand.and.sparkles")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
    }

    // MARK: Actions

    private func loadImages() async {
        if let data = design.resultImageData {
            result = await LocalImageCache.shared.image(key: "\(design.id)-result-full", data: data, maxPixelSize: 3072)
        }
        if let data = design.originalImageData {
            original = await LocalImageCache.shared.image(key: "\(design.id)-original-full", data: data, maxPixelSize: 3072)
        }
    }

    /// Writes the design (and the original) to temporary files and opens them in Quick Look,
    /// so the user can swipe between "Design" and "Original" like photos in an album.
    private func openPreview() {
        guard let resultData = design.resultImageData else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(design.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [URL] = []
        let designURL = folder.appendingPathComponent("\(design.styleTitle) \(design.subjectTitle).jpg")
        if (try? resultData.write(to: designURL, options: .atomic)) != nil { items.append(designURL) }
        if let originalData = design.originalImageData {
            let originalURL = folder.appendingPathComponent("Original.jpg")
            if (try? originalData.write(to: originalURL, options: .atomic)) != nil { items.append(originalURL) }
        }
        guard let first = items.first else { return }
        previewItems = items
        previewURL = first
    }

    private func saveToPhotos() async {
        guard let data = design.resultImageData else { return }
        saveState = .saving
        saveError = nil
        do {
            try await PhotoLibrarySaver.save(imageData: data)
            withAnimation { saveState = .saved }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { saveState = .idle }
        } catch {
            saveState = .idle
            saveError = error.localizedDescription
        }
    }
}

/// Describe a change; a new design is generated from this result.
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
