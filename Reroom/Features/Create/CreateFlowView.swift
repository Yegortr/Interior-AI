import SwiftUI

/// Photo → room → style → wishes → generate. The design appears in the gallery immediately.
struct CreateFlowView: View {
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable { case photo, room, style, wishes }

    @State private var step: Step = .photo
    @State private var isForward = true
    @State private var photo: PickedPhoto?
    @State private var roomType: RoomType = .livingRoom
    @State private var style: InteriorStyle = .modern
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            QuestionnaireScaffold(
                step: step.rawValue,
                stepCount: Step.allCases.count,
                title: title,
                subtitle: subtitle,
                isForward: isForward,
                canContinue: step != .photo || photo != nil,
                continueTitle: step == .wishes ? "Generate" : "Continue",
                onBack: step == .photo ? nil : { move(by: -1) },
                onContinue: {
                    if step == .wishes { generate() } else { move(by: 1) }
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
        case .photo: "Photograph your room"
        case .room: "What room is it?"
        case .style: "Choose a style"
        case .wishes: "Anything specific?"
        }
    }

    private var subtitle: String? {
        switch step {
        case .photo: "Stand in a corner and capture as much of the room as you can, in good light."
        case .room: nil
        case .style: nil
        case .wishes: "Optional — e.g. \"keep the fireplace\" or \"add a reading nook\"."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .photo:
            SinglePhotoInput(photo: $photo, title: "Add a room photo")

        case .room:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(RoomType.allCases) { room in
                    RoomTile(room: room, isSelected: roomType == room) {
                        Haptics.tap()
                        roomType = room
                    }
                }
            }

        case .style:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(InteriorStyle.allCases) { item in
                    SwatchTile(title: item.title, subtitle: item.promptDetails, colors: item.swatch, isSelected: style == item) {
                        Haptics.tap()
                        style = item
                    }
                }
            }

        case .wishes:
            if let photo {
                Image(uiImage: photo.preview)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            FlowLayout(spacing: 8) {
                Chip(title: roomType.title, symbol: roomType.symbol)
                Chip(title: style.title, symbol: "paintpalette")
            }
            TextField("Your wishes (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
            FlowLayout(spacing: 8) {
                ForEach(["Keep the furniture layout", "Add plants", "Brighter lighting", "Add a rug", "Built-in shelving"], id: \.self) { idea in
                    Button {
                        Haptics.tap()
                        notes = notes.isEmpty ? idea : "\(notes), \(idea.lowercased())"
                    } label: {
                        Chip(title: idea, symbol: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func move(by delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        isForward = delta > 0
        withAnimation(Theme.spring) { step = next }
    }

    private func generate() {
        guard let photo else { return }
        coordinator.create(roomType: roomType, style: style, notes: notes, photo: photo.prepared)
        Haptics.success()
        dismiss()
    }
}

private struct RoomTile: View {
    let room: RoomType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: room.symbol)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                Text(room.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 16)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 48, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 48, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.pressable)
        .animation(Theme.snappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
