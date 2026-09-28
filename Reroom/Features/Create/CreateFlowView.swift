import SwiftUI

/// Room flow. Each step is pushed on a NavigationStack: system Back button and swipe-back.
struct CreateFlowView: View {
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable { case room, style, wishes }
    private let stepCount = 4

    @State private var path: [Step] = []
    @State private var photo: PickedPhoto?
    @State private var roomType: RoomType = .livingRoom
    @State private var style: InteriorStyle = .modern
    @State private var notes = ""

    private let ideas = ["Keep the furniture layout", "Add plants", "Brighter lighting", "Add a rug", "Built-in shelving"]

    var body: some View {
        NavigationStack(path: $path) {
            FlowStep(index: 0, count: stepCount, title: "Your Room", buttonTitle: "Continue", canContinue: photo != nil) {
                path.append(.room)
            } content: {
                PhotoSection(photo: $photo, footer: "Stand in a corner and capture as much of the room as you can, in good light.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .room: roomStep
                case .style: styleStep
                case .wishes: wishesStep
                }
            }
        }
        .sensoryFeedback(.selection, trigger: roomType)
        .sensoryFeedback(.selection, trigger: style)
        .sensoryFeedback(.impact(weight: .light), trigger: path.count)
    }

    private var roomStep: some View {
        FlowStep(index: 1, count: stepCount, title: "Room Type", buttonTitle: "Continue", canContinue: true) {
            path.append(.style)
        } content: {
            Section {
                Picker("Room", selection: $roomType) {
                    ForEach(RoomType.allCases) { room in
                        Label(room.title, systemImage: room.symbol).tag(room)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private var styleStep: some View {
        FlowStep(index: 2, count: stepCount, title: "Style", buttonTitle: "Continue", canContinue: true) {
            path.append(.wishes)
        } content: {
            Section {
                Picker("Style", selection: $style) {
                    ForEach(InteriorStyle.allCases) { item in
                        StyleRow(title: item.title, details: item.promptDetails, colors: item.swatch).tag(item)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private var wishesStep: some View {
        FlowStep(index: 3, count: stepCount, title: "Wishes", buttonTitle: "Generate", buttonSymbol: "wand.and.sparkles", canContinue: photo != nil) {
            generate()
        } content: {
            Section {
                TextField("E.g. keep the fireplace", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Anything specific?")
            } footer: {
                Text("Optional.")
            }
            Section("Ideas") {
                ForEach(ideas, id: \.self) { idea in
                    Button {
                        notes = notes.isEmpty ? idea : "\(notes), \(idea.lowercased())"
                    } label: {
                        Label(idea, systemImage: "plus.circle")
                    }
                }
            }
            Section("Summary") {
                LabeledContent("Room") { Label(roomType.title, systemImage: roomType.symbol) }
                LabeledContent("Style", value: style.title)
            }
        }
    }

    private func generate() {
        guard let photo else { return }
        coordinator.create(roomType: roomType, style: style, notes: notes, photo: photo.prepared)
        dismiss()
    }
}

/// Picker row for a style: a two-tone swatch, the name and a short description.
struct StyleRow: View {
    let title: String
    let details: String
    let colors: (String, String)

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(hex: colors.0) ?? .gray, Color(hex: colors.1) ?? .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
