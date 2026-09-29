import SwiftUI

struct DesignDetailActions {
    var openViewer: () -> Void
    var openPlant: (Plant) -> Void
}

struct DesignDetailView: View {
    let design: Design
    @Bindable var state: DesignDetailState
    let heroAnchor: ViewBox
    let heroImage: ViewBox
    let actions: DesignDetailActions

    var body: some View {
        List {
            Section {
                hero
                    .background(ZoomAnchor(box: heroAnchor))     // the zoom lines the grid cell up with this
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if design.status == .completed, state.original != nil {
                    Picker("View", selection: $state.mode) {
                        ForEach(DesignDetailState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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

            if let saveError = state.saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sensoryFeedback(.selection, trigger: state.mode)
        .sensoryFeedback(.impact(weight: .medium), trigger: design.isFavorite)
        .sensoryFeedback(.success, trigger: state.saveState) { _, new in new == .saved }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if design.status != .completed {
            Color.clear
                .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                .overlay {
                    ZStack {
                        if let original = state.original {
                            Image(uiImage: original).resizable().scaledToFill()
                                .blur(radius: 14)
                                .opacity(0.45)
                        }
                        Rectangle().fill(.ultraThinMaterial)
                        PendingStatusView(design: design, compact: false).padding(24)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if state.mode == .compare, let result = state.result, let original = state.original {
            BeforeAfterSlider(before: original, after: result, aspectRatio: design.aspectRatio.value)
                .transition(.opacity)
        } else {
            Button(action: actions.openViewer) {
                Color.clear
                    .aspectRatio(design.aspectRatio.value, contentMode: .fit)
                    .overlay { HeroImage(image: state.result, placeholder: state.placeholder, box: heroImage) }
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
                    // Pushed by UIKit (the spine); looks and highlights like a NavigationLink row.
                    Button {
                        actions.openPlant(plant)
                    } label: {
                        HStack {
                            PlantRow(plant: plant)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
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
}

/// Describe a change; a new design is generated from this result. Presented by UIKit
/// (medium/large detents); it reports back instead of dismissing itself.
struct MakeChangesSheet: View {
    let design: Design
    let onCancel: () -> Void
    let onApply: (String) -> Void

    @State private var change = ""
    @FocusState private var focused: Bool

    private var ideas: [String] {
        design.kind == .garden
            ? ["Add a stone pathway", "More flowering plants", "Add warm string lights", "Replace lawn with gravel", "Add a bench"]
            : ["Make it brighter", "Swap the sofa for a green velvet one", "Add indoor plants", "Warmer wood tones", "Change wall color to sage"]
    }

    private var trimmed: String { change.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(trimmed) }
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
