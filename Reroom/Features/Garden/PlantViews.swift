import SwiftUI

/// List row: thumbnail, common and scientific name, pet-safe badge.
struct PlantRow: View {
    let plant: Plant

    var body: some View {
        HStack(spacing: 12) {
            PlantImage(url: plant.imageUrl)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.name)
                if let scientific = plant.scientificName {
                    Text(scientific)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if plant.petSafe == true {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.teal)
                    .accessibilityLabel("Pet-safe")
            }
        }
        .padding(.vertical, 2)
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
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(.green.opacity(0.6))
                        .symbolEffect(.breathe, isActive: url != nil)
                }
            }
        }
    }
}

/// Native, Settings-style plant page pushed from the design.
struct PlantDetailView: View {
    let plant: Plant
    let locationName: String?

    private struct Fact: Identifiable {
        let title: String
        let value: String
        let symbol: String
        let color: Color
        var id: String { title }
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let sun = plant.sun { facts.append(Fact(title: "Light", value: sun, symbol: "sun.max.fill", color: .orange)) }
        if let water = plant.water { facts.append(Fact(title: "Water", value: water, symbol: "drop.fill", color: .blue)) }
        if let care = plant.careLevel { facts.append(Fact(title: "Care", value: care, symbol: "hand.raised.fill", color: .green)) }
        if let petSafe = plant.petSafe {
            facts.append(Fact(title: "Pets", value: petSafe ? "Non-toxic" : "Toxic", symbol: "pawprint.fill", color: petSafe ? .teal : .red))
        }
        if let hardiness = plant.hardiness { facts.append(Fact(title: "Hardiness", value: hardiness, symbol: "thermometer.snowflake", color: .purple)) }
        if let height = plant.height { facts.append(Fact(title: "Height", value: height, symbol: "ruler.fill", color: .brown)) }
        if let bloom = plant.bloomSeason { facts.append(Fact(title: "Blooms", value: bloom, symbol: "camera.macro", color: .pink)) }
        return facts
    }

    var body: some View {
        List {
            Section {
                Color.clear
                    .aspectRatio(1.25, contentMode: .fit)
                    .overlay { PlantImage(url: plant.imageUrl) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if let scientific = plant.scientificName {
                    Text(scientific).italic().font(.subheadline)
                }
            }

            if let reason = plant.reason {
                Section(locationName.map { "Why it thrives in \($0)" } ?? "Why this plant") {
                    Text(reason)
                }
            }

            if !facts.isEmpty {
                Section("At a Glance") {
                    ForEach(facts) { fact in
                        LabeledContent {
                            Text(fact.value)
                        } label: {
                            Label {
                                Text(fact.title)
                            } icon: {
                                Image(systemName: fact.symbol)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(fact.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                        }
                    }
                }
            }

            if !plant.careTips.isEmpty {
                Section("Care Tips") {
                    ForEach(Array(plant.careTips.enumerated()), id: \.offset) { _, tip in
                        Label {
                            Text(tip)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(plant.name)
        .navigationBarTitleDisplayMode(.large)
    }
}
