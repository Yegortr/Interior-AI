import SwiftUI

struct DesignDetailView: View {
    let design: Design

    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .design
    @State private var result: UIImage?
    @State private var original: UIImage?
    @State private var showFullscreen = false
    @State private var showMakeChanges = false
    @State private var confirmDelete = false
    @State private var saveState: SaveState = .idle
    @State private var selectedPlant: Plant?

    private enum Mode: String, CaseIterable { case design = "Design", compare = "Before & After" }
    private enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if design.status == .completed {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in Haptics.tap() }

                    hero
                    actions
                } else {
                    Color.clear
                        .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                        .overlay {
                            ZStack {
                                DesignImage(design: design, kind: .original, maxPixelSize: 1200)
                                    .blur(radius: 14)
                                    .opacity(0.45)
                                Rectangle().fill(Theme.placeholderGradient)
                                PendingStatusView(design: design, compact: false).padding(24)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                }

                if case .failed(let message) = saveState {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }

                FlowLayout(spacing: 8) {
                    if design.kind == .garden {
                        Chip(title: "Garden", symbol: "leaf")
                        if let place = design.locationName { Chip(title: place, symbol: "mappin.and.ellipse") }
                    } else {
                        Chip(title: design.roomType.title, symbol: design.roomType.symbol)
                    }
                    Chip(title: design.styleTitle, symbol: "paintpalette")
                    Chip(title: design.createdAt.formatted(date: .abbreviated, time: .shortened), symbol: "calendar")
                }

                if design.kind == .garden {
                    gardenSection
                }

                if !design.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(design.parentId == nil ? "Your wishes" : "Requested change").font(.headline)
                        Text(design.notes).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.horizontalPadding)
            .animation(Theme.spring, value: mode)
            .animation(Theme.spring, value: design.statusRaw)
        }
        .navigationTitle(design.styleTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if design.isRetryable {
                        Button { coordinator.retry(design) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if design.status == .completed {
                Button {
                    Haptics.tap()
                    showMakeChanges = true
                } label: {
                    Label("Make Changes", systemImage: "wand.and.stars")
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 8)
            }
        }
        .confirmationDialog("Delete this design?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                // Delete after the pop animation so this screen never reads a deleted model.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { coordinator.delete(design) }
            }
        }
        .sheet(isPresented: $showMakeChanges) {
            MakeChangesSheet(design: design) { dismiss() }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            if let result {
                FullscreenViewer(after: result, before: original) { setFullscreen(false) }
                    .presentationBackground(.clear)
            }
        }
        .sheet(item: $selectedPlant) { plant in
            PlantDetailSheet(plant: plant, locationName: design.locationName)
        }
        .task(id: design.statusRaw) { await loadImages() }
    }

    @ViewBuilder
    private var hero: some View {
        if mode == .compare, let result, let original {
            BeforeAfterSlider(before: original, after: result, aspectRatio: design.aspectRatio.value)
                .transition(.opacity)
        } else {
            Color.clear
                .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                .overlay {
                    if let result {
                        Image(uiImage: result).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.placeholderGradient)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { setFullscreen(true) }
                .transition(.opacity)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            actionButton(design.isFavorite ? "Saved" : "Favorite", systemImage: design.isFavorite ? "heart.fill" : "heart", tint: design.isFavorite ? .pink : .accentColor) {
                Haptics.impact()
                design.isFavorite.toggle()
            }
            actionButton(saveTitle, systemImage: saveIcon, tint: .accentColor) {
                Task { await saveToPhotos() }
            }
            .disabled(saveState == .saving)
            if let result {
                ShareLink(item: Image(uiImage: result), preview: SharePreview("Reroom design", image: Image(uiImage: result))) {
                    actionLabel("Share", systemImage: "square.and.arrow.up", tint: .accentColor)
                }
                .buttonStyle(.pressable)
            }
            actionButton("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", tint: .accentColor) {
                Haptics.tap()
                setFullscreen(true)
            }
        }
    }

    @ViewBuilder
    private var gardenSection: some View {
        let plants = design.plants
        if let notes = design.designNotes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Design notes").font(.headline)
                Text(notes).foregroundStyle(.secondary)
            }
        }
        if plants.isEmpty {
            if design.status.isInProgress {
                Label("Choosing plants for \(design.locationName ?? "your climate")…", systemImage: "leaf")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Plants for your garden",
                    subtitle: design.locationName.map { "Picked to thrive in \($0)" }
                )
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(plants) { plant in
                        Button {
                            Haptics.tap()
                            selectedPlant = plant
                        } label: {
                            PlantCard(plant: plant)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    private var saveTitle: String {
        switch saveState {
        case .idle, .failed: "Save"
        case .saving: "Saving…"
        case .saved: "Saved"
        }
    }

    private var saveIcon: String {
        saveState == .saved ? "checkmark" : "arrow.down.to.line"
    }

    private func actionButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, systemImage: systemImage, tint: tint) }
            .buttonStyle(.pressable)
    }

    private func actionLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.caption).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func setFullscreen(_ presented: Bool) {
        guard result != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showFullscreen = presented }
    }

    private func loadImages() async {
        if let data = design.resultImageData {
            result = await LocalImageCache.shared.image(key: "\(design.id)-result-full", data: data, maxPixelSize: 3072)
        }
        if let data = design.originalImageData {
            original = await LocalImageCache.shared.image(key: "\(design.id)-original-full", data: data, maxPixelSize: 3072)
        }
    }

    private func saveToPhotos() async {
        guard let data = design.resultImageData else { return }
        saveState = .saving
        do {
            try await PhotoLibrarySaver.save(imageData: data)
            Haptics.success()
            withAnimation { saveState = .saved }
        } catch {
            Haptics.error()
            saveState = .failed(error.localizedDescription)
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

    private let ideas = ["Make it brighter", "Swap the sofa for a green velvet one", "Add indoor plants", "Warmer wood tones", "Add a large rug", "Change wall color to sage"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("What should change?", text: $change, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
                    FlowLayout(spacing: 8) {
                        ForEach(ideas, id: \.self) { idea in
                            Button {
                                Haptics.tap()
                                change = change.isEmpty ? idea : "\(change), \(idea.lowercased())"
                            } label: {
                                Chip(title: idea, symbol: "plus")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Theme.horizontalPadding)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    coordinator.makeChanges(from: design, change: change)
                    Haptics.success()
                    dismiss()
                    onSubmitted()
                } label: {
                    Label("Apply Changes", systemImage: "wand.and.stars")
                }
                .buttonStyle(.primary)
                .disabled(change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(Theme.horizontalPadding)
            }
            .navigationTitle("Make Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
