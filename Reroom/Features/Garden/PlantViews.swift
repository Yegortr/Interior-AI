import SwiftUI

struct PlantCard: View {
    let plant: Plant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { PlantImage(url: plant.imageUrl) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if plant.petSafe == true {
                        Image(systemName: "pawprint.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.teal, in: Circle())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let scientific = plant.scientificName {
                    Text(scientific).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

struct PlantImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(Theme.placeholderGradient)
                    .overlay(Image(systemName: "leaf").font(.title).foregroundStyle(Color.accentColor.opacity(0.6)))
            }
        }
    }
}

/// Plant sheet with a Greg-style grid of colored care tiles.
struct PlantDetailSheet: View {
    let plant: Plant
    let locationName: String?

    @State private var detent: PresentationDetent = .medium

    private struct Fact: Identifiable {
        let title: String
        let value: String
        let symbol: String
        let tint: Color
        var id: String { title }
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let sun = plant.sun { facts.append(Fact(title: "Light", value: sun, symbol: "sun.max.fill", tint: .orange)) }
        if let water = plant.water { facts.append(Fact(title: "Water", value: water, symbol: "drop.fill", tint: .blue)) }
        if let care = plant.careLevel { facts.append(Fact(title: "Care", value: care, symbol: "hand.raised.fill", tint: .green)) }
        if let petSafe = plant.petSafe {
            facts.append(Fact(title: "Pets", value: petSafe ? "Non-toxic" : "Toxic", symbol: "pawprint.fill", tint: petSafe ? .teal : .red))
        }
        if let hardiness = plant.hardiness { facts.append(Fact(title: "Hardiness", value: hardiness, symbol: "thermometer.medium", tint: .purple)) }
        if let height = plant.height { facts.append(Fact(title: "Height", value: height, symbol: "ruler", tint: .brown)) }
        if let bloom = plant.bloomSeason { facts.append(Fact(title: "Blooms", value: bloom, symbol: "camera.macro", tint: .pink)) }
        return facts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Color.clear
                    .aspectRatio(1.2, contentMode: .fit)
                    .overlay { PlantImage(url: plant.imageUrl) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(plant.name).font(.title2.bold())
                    if let scientific = plant.scientificName {
                        Text(scientific).italic().foregroundStyle(.secondary)
                    }
                }

                if let reason = plant.reason {
                    Label {
                        Text(reason)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(Color.accentColor)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                    .accessibilityLabel("Why it suits \(locationName ?? "your garden"): \(reason)")
                }

                if !facts.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(facts) { fact in
                            HStack(spacing: 10) {
                                Image(systemName: fact.symbol)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fact.tint))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(fact.title).font(.caption).foregroundStyle(.secondary)
                                    Text(fact.value).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if !plant.careTips.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Care tips").font(.headline)
                        ForEach(Array(plant.careTips.enumerated()), id: \.offset) { _, tip in
                            Label {
                                Text(tip)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onChange(of: detent) { _, _ in Haptics.snap() }
    }
}
