import SwiftUI

/// Garden flow: photo → location → sunlight → style → care → extras → generate.
/// Native pushed Form steps; the location drives regional plant picks on the server.
struct GardenFlowView: View {
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable { case location, sunlight, style, care, extras }
    private let stepCount = 6

    @State private var path: [Step] = []
    @State private var photo: PickedPhoto?
    @State private var location: GardenLocation?
    @State private var sunlight: Sunlight = .fullSun
    @State private var style: GardenStyle = .englishCottage
    @State private var maintenance: MaintenanceLevel = .medium
    @State private var petSafe = false
    @State private var hardscaping: Set<Hardscape> = []
    @State private var notes = ""

    var body: some View {
        NavigationStack(path: $path) {
            FlowStep(index: 0, count: stepCount, title: "Your Garden", buttonTitle: "Continue", canContinue: photo != nil) {
                path.append(.location)
            } content: {
                PhotoSection(photo: $photo, footer: "A wide photo of the whole yard, balcony or terrace works best.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .location: locationStep
                case .sunlight: sunlightStep
                case .style: styleStep
                case .care: careStep
                case .extras: extrasStep
                }
            }
        }
        .sensoryFeedback(.selection, trigger: sunlight)
        .sensoryFeedback(.selection, trigger: style)
        .sensoryFeedback(.selection, trigger: maintenance)
        .sensoryFeedback(.selection, trigger: hardscaping)
        .sensoryFeedback(.impact(weight: .light), trigger: path.count)
    }

    private var locationStep: some View {
        FlowStep(index: 1, count: stepCount, title: "Location", buttonTitle: "Continue", canContinue: location != nil) {
            path.append(.sunlight)
        } content: {
            LocationSection(location: $location)
        }
    }

    private var sunlightStep: some View {
        FlowStep(index: 2, count: stepCount, title: "Sunlight", buttonTitle: "Continue", canContinue: true) {
            path.append(.style)
        } content: {
            Section {
                Picker("Sunlight", selection: $sunlight) {
                    ForEach(Sunlight.allCases) { option in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: option.symbol).symbolRenderingMode(.multicolor)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Think about the sunniest part of the space.")
            }
        }
    }

    private var styleStep: some View {
        FlowStep(index: 3, count: stepCount, title: "Style", buttonTitle: "Continue", canContinue: true) {
            path.append(.care)
        } content: {
            Section {
                Picker("Style", selection: $style) {
                    ForEach(GardenStyle.allCases) { item in
                        StyleRow(title: item.title, details: item.promptDetails, colors: item.swatch).tag(item)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private var careStep: some View {
        FlowStep(index: 4, count: stepCount, title: "Care", buttonTitle: "Continue", canContinue: true) {
            path.append(.extras)
        } content: {
            Section("Time for the garden") {
                Picker("Maintenance", selection: $maintenance) {
                    ForEach(MaintenanceLevel.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                            Text(level.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle(isOn: $petSafe) {
                    Label("Pet-Safe Plants Only", systemImage: "pawprint.fill")
                }
            } footer: {
                Text("Skips plants that are toxic to cats and dogs.")
            }
        }
    }

    private var extrasStep: some View {
        FlowStep(index: 5, count: stepCount, title: "Finishing Touches", buttonTitle: "Design My Garden", buttonSymbol: "wand.and.sparkles", canContinue: photo != nil && location != nil) {
            generate()
        } content: {
            Section("Structures") {
                ForEach(Hardscape.allCases) { element in
                    let isSelected = hardscaping.contains(element)
                    Button {
                        if isSelected { hardscaping.remove(element) } else { hardscaping.insert(element) }
                    } label: {
                        HStack {
                            Label(element.title, systemImage: element.symbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .opacity(isSelected ? 1 : 0)
                                .symbolEffect(.bounce, value: isSelected)
                        }
                    }
                }
            }
            Section {
                TextField("E.g. keep the old apple tree", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Wishes")
            } footer: {
                if let location {
                    Text("Plants will be chosen to thrive in \(location.name).")
                }
            }
        }
    }

    private func generate() {
        guard let photo, let location else { return }
        let context = GardenContext(
            location: location,
            month: Calendar.current.component(.month, from: Date()),
            sunlight: sunlight,
            style: style,
            maintenance: maintenance,
            petSafe: petSafe,
            hardscaping: Hardscape.allCases.filter { hardscaping.contains($0) },
            notes: notes
        )
        coordinator.createGarden(context, photo: photo.prepared)
        dismiss()
    }
}

/// "Use My Location" or a typed city, as native Form rows.
private struct LocationSection: View {
    @Binding var location: GardenLocation?

    @State private var service = LocationService()
    @State private var isLocating = false
    @State private var errorMessage: String?
    @State private var manualName = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Section {
            if let location {
                HStack {
                    Label {
                        Text(location.name)
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .symbolEffect(.bounce, value: location)
                    }
                    Spacer()
                    Button("Change") {
                        withAnimation { self.location = nil }
                    }
                    .buttonStyle(.borderless)
                }
                .sensoryFeedback(.success, trigger: location)
            } else {
                Button {
                    Task { await locate() }
                } label: {
                    HStack {
                        Label {
                            Text("Use My Location")
                        } icon: {
                            Image(systemName: "location.fill")
                                .symbolEffect(.pulse, isActive: isLocating)
                        }
                        Spacer()
                        if isLocating { ProgressView() }
                    }
                }
                .disabled(isLocating)

                HStack {
                    TextField("Or type your city", text: $manualName)
                        .textContentType(.addressCity)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(useManual)
                    if !manualName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Use", action: useManual)
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                    }
                }
            }
        } header: {
            Text("Where is your garden?")
        } footer: {
            Text(errorMessage ?? "We pick plants that thrive in your climate. Only your approximate area is used — never your address.")
        }
    }

    private func locate() async {
        isLocating = true
        errorMessage = nil
        defer { isLocating = false }
        do {
            let found = try await service.currentLocation()
            withAnimation { location = found }
        } catch {
            errorMessage = error.localizedDescription
            fieldFocused = true
        }
    }

    private func useManual() {
        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        fieldFocused = false
        withAnimation { location = GardenLocation(name: name) }
    }
}
