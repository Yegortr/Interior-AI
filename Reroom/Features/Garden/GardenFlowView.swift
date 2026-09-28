import SwiftUI

/// Photo → where → sunlight → style → care → extras → generate.
/// The location drives the plant picks: the server chooses plants that thrive in that climate.
struct GardenFlowView: View {
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable { case photo, location, sunlight, style, care, extras }

    @State private var step: Step = .photo
    @State private var isForward = true
    @State private var photo: PickedPhoto?
    @State private var location: GardenLocation?
    @State private var sunlight: Sunlight = .fullSun
    @State private var style: GardenStyle = .englishCottage
    @State private var maintenance: MaintenanceLevel = .medium
    @State private var petSafe = false
    @State private var hardscaping: Set<Hardscape> = []
    @State private var notes = ""

    private var canContinue: Bool {
        switch step {
        case .photo: photo != nil
        case .location: location != nil
        default: true
        }
    }

    var body: some View {
        NavigationStack {
            QuestionnaireScaffold(
                step: step.rawValue,
                stepCount: Step.allCases.count,
                title: title,
                subtitle: subtitle,
                isForward: isForward,
                canContinue: canContinue,
                continueTitle: step == .extras ? "Design My Garden" : "Continue",
                onBack: step == .photo ? nil : { move(by: -1) },
                onContinue: {
                    if step == .extras { generate() } else { move(by: 1) }
                }
            ) {
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        switch step {
        case .photo: "Show us your garden"
        case .location: "Where is it?"
        case .sunlight: "How much sun?"
        case .style: "Pick a garden style"
        case .care: "Care & safety"
        case .extras: "Finishing touches"
        }
    }

    private var subtitle: String? {
        switch step {
        case .photo: "A wide photo of the whole yard, balcony or terrace works best."
        case .location: "We'll pick plants that actually thrive in your climate."
        case .sunlight: "Think about the sunniest part of the space."
        case .style: nil
        case .care: "How much time will you spend on it?"
        case .extras: "Add structures and wishes — all optional."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .photo:
            SinglePhotoInput(photo: $photo, title: "Add a garden photo")

        case .location:
            LocationPicker(location: $location)

        case .sunlight:
            ForEach(Sunlight.allCases) { option in
                OptionCard(title: option.title, subtitle: option.subtitle, symbol: option.symbol, isSelected: sunlight == option) {
                    sunlight = option
                }
            }

        case .style:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(GardenStyle.allCases) { item in
                    SwatchTile(
                        title: item.title,
                        subtitle: item.promptDetails,
                        colors: item.swatch,
                        isSelected: style == item
                    ) {
                        Haptics.tap()
                        style = item
                    }
                }
            }

        case .care:
            ForEach(MaintenanceLevel.allCases) { level in
                OptionCard(title: level.title, subtitle: level.subtitle, symbol: "clock", isSelected: maintenance == level) {
                    maintenance = level
                }
            }
            Toggle(isOn: $petSafe) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pet-safe plants only")
                        Text("Skip plants toxic to cats and dogs").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "pawprint.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color(.secondarySystemBackground)))
            .onChange(of: petSafe) { _, _ in Haptics.tap() }

        case .extras:
            FlowLayout(spacing: 10) {
                ForEach(Hardscape.allCases) { element in
                    let isSelected = hardscaping.contains(element)
                    Button {
                        Haptics.tap()
                        if isSelected { hardscaping.remove(element) } else { hardscaping.insert(element) }
                    } label: {
                        Chip(title: element.title, symbol: element.symbol, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(Theme.snappy, value: hardscaping)
            TextField("Anything else? (e.g. keep the old apple tree)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
            if let location {
                Label("Plants will be chosen for \(location.name)", systemImage: "leaf")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func move(by delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        isForward = delta > 0
        withAnimation(Theme.spring) { step = next }
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
        Haptics.success()
        dismiss()
    }
}

/// "Use my location" or type a city (Wolt/Beli-style), showing the chosen place.
private struct LocationPicker: View {
    @Binding var location: GardenLocation?

    @State private var service = LocationService()
    @State private var isLocating = false
    @State private var errorMessage: String?
    @State private var manualName = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "map.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .frame(width: 110, height: 110)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                .symbolEffect(.pulse, isActive: isLocating)
                .frame(maxWidth: .infinity)

            if let location {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.name).font(.headline)
                        Text("Plants will be matched to this climate").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") {
                        Haptics.tap()
                        withAnimation(Theme.spring) { self.location = nil }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else {
                Button {
                    Task { await locate() }
                } label: {
                    if isLocating {
                        ProgressView().tint(.white)
                    } else {
                        Label("Use My Location", systemImage: "location.fill")
                    }
                }
                .buttonStyle(.primary)
                .disabled(isLocating)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Or type your city", text: $manualName)
                        .textContentType(.addressCity)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(useManual)
                    if !manualName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Use", action: useManual).font(.subheadline.weight(.semibold))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
            }

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Text("Only your approximate area is used, never your address.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .animation(Theme.spring, value: location)
    }

    private func locate() async {
        Haptics.tap()
        isLocating = true
        errorMessage = nil
        defer { isLocating = false }
        do {
            location = try await service.currentLocation()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            fieldFocused = true
        }
    }

    private func useManual() {
        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Haptics.tap()
        fieldFocused = false
        location = GardenLocation(name: name)
    }
}

/// Gradient tile for a style choice (rooms and gardens).
struct SwatchTile: View {
    let title: String
    let subtitle: String
    let colors: (String, String)
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                LinearGradient(
                    colors: [Color(hex: colors.0) ?? .gray, Color(hex: colors.1) ?? .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 90)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 45, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 45, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title2)
                            .padding(10)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.pressable)
        .animation(Theme.snappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
