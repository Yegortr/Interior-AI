import Foundation

enum DesignKind: String, Codable, CaseIterable, Sendable {
    case interior, garden

    var title: String { self == .interior ? "Room" : "Garden" }
    var symbol: String { self == .interior ? "sofa" : "leaf" }
}

enum GardenStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case englishCottage = "english_cottage", modernZen = "modern_zen", mediterranean
    case tropical, desert, wildMeadow = "wild_meadow", kitchenGarden = "kitchen_garden", minimalModern = "minimal_modern"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .englishCottage: "English Cottage"
        case .modernZen: "Modern Zen"
        case .mediterranean: "Mediterranean"
        case .tropical: "Tropical"
        case .desert: "Desert"
        case .wildMeadow: "Wild Meadow"
        case .kitchenGarden: "Kitchen Garden"
        case .minimalModern: "Minimal Modern"
        }
    }

    var promptDetails: String {
        switch self {
        case .englishCottage: "abundant flowering borders, roses and climbers, curving paths, romantic informal planting"
        case .modernZen: "clean lines, raked gravel, stone, moss, Japanese maples, calm and balanced composition"
        case .mediterranean: "olive trees, lavender, rosemary, terracotta pots, warm stone and gravel"
        case .tropical: "lush large-leaved foliage, palms, bold colors, layered dense planting"
        case .desert: "succulents, agaves, cacti, sculptural forms, gravel and boulders"
        case .wildMeadow: "naturalistic grasses and wildflowers, pollinator friendly, soft mown paths"
        case .kitchenGarden: "raised vegetable beds, herbs, fruit trees, neat gravel paths, productive and pretty"
        case .minimalModern: "architectural planting, large-format paving, clipped hedges, restrained palette"
        }
    }

    var swatch: (String, String) {
        switch self {
        case .englishCottage: ("#F3D1DC", "#5E8C4A")
        case .modernZen: ("#D8D5CC", "#3F5D45")
        case .mediterranean: ("#E9D8B4", "#7A8F5A")
        case .tropical: ("#2E8B57", "#F2A541")
        case .desert: ("#E7C9A0", "#8A9A5B")
        case .wildMeadow: ("#E8E3B0", "#8FB569")
        case .kitchenGarden: ("#C8A77A", "#4F7F3A")
        case .minimalModern: ("#E4E4E0", "#2F3B34")
        }
    }
}

enum Sunlight: String, CaseIterable, Identifiable, Codable, Sendable {
    case fullSun = "full_sun", partialSun = "partial_sun", shade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullSun: "Full Sun"
        case .partialSun: "Partial Sun"
        case .shade: "Shade"
        }
    }

    var subtitle: String {
        switch self {
        case .fullSun: "6+ hours of direct sun"
        case .partialSun: "3–6 hours of sun"
        case .shade: "Less than 3 hours"
        }
    }

    var symbol: String {
        switch self {
        case .fullSun: "sun.max.fill"
        case .partialSun: "cloud.sun.fill"
        case .shade: "cloud.fill"
        }
    }
}

enum MaintenanceLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case low, medium, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var subtitle: String {
        switch self {
        case .low: "A few minutes a week"
        case .medium: "Weekend gardening"
        case .high: "I love spending time in the garden"
        }
    }
}

enum Hardscape: String, CaseIterable, Identifiable, Codable, Sendable {
    case patio, pathway, pergola, waterFeature = "water_feature", firePit = "fire_pit", raisedBeds = "raised_beds"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .patio: "Patio"
        case .pathway: "Pathway"
        case .pergola: "Pergola"
        case .waterFeature: "Water Feature"
        case .firePit: "Fire Pit"
        case .raisedBeds: "Raised Beds"
        }
    }

    var symbol: String {
        switch self {
        case .patio: "square.grid.3x3.fill"
        case .pathway: "point.topleft.down.to.point.bottomright.curvepath"
        case .pergola: "house.lodge"
        case .waterFeature: "drop.fill"
        case .firePit: "flame"
        case .raisedBeds: "square.stack.3d.up"
        }
    }
}

/// Where the garden is. Coordinates are rounded (~10 km) — enough for climate, not an address.
struct GardenLocation: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double?
    var longitude: Double?

    init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        self.latitude = latitude.map { ($0 * 10).rounded() / 10 }
        self.longitude = longitude.map { ($0 * 10).rounded() / 10 }
    }
}

/// Garden answers sent to the server, which picks regional plants (Gemini) before rendering.
struct GardenContext: Codable, Hashable, Sendable {
    var location: GardenLocation
    var month: Int
    var sunlight: Sunlight
    var style: GardenStyle
    var maintenance: MaintenanceLevel
    var petSafe: Bool
    var hardscaping: [Hardscape]
    var notes: String
}

/// A plant recommended for this garden and region.
struct Plant: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var scientificName: String?
    /// Why it suits this region/garden.
    var reason: String?
    var sun: String?
    var water: String?
    var careLevel: String?
    var petSafe: Bool?
    var hardiness: String?
    var height: String?
    var bloomSeason: String?
    var careTips: [String]
    var imageUrl: URL?

    var id: String { name.lowercased() }

    init(name: String, scientificName: String? = nil, reason: String? = nil, sun: String? = nil, water: String? = nil,
         careLevel: String? = nil, petSafe: Bool? = nil, hardiness: String? = nil, height: String? = nil,
         bloomSeason: String? = nil, careTips: [String] = [], imageUrl: URL? = nil) {
        self.name = name
        self.scientificName = scientificName
        self.reason = reason
        self.sun = sun
        self.water = water
        self.careLevel = careLevel
        self.petSafe = petSafe
        self.hardiness = hardiness
        self.height = height
        self.bloomSeason = bloomSeason
        self.careTips = careTips
        self.imageUrl = imageUrl
    }

    /// Lenient: the list comes from an LLM, so missing or odd fields must not drop the plant.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        scientificName = try? c.decodeIfPresent(String.self, forKey: .scientificName)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        sun = try? c.decodeIfPresent(String.self, forKey: .sun)
        water = try? c.decodeIfPresent(String.self, forKey: .water)
        careLevel = try? c.decodeIfPresent(String.self, forKey: .careLevel)
        petSafe = try? c.decodeIfPresent(Bool.self, forKey: .petSafe)
        hardiness = try? c.decodeIfPresent(String.self, forKey: .hardiness)
        height = try? c.decodeIfPresent(String.self, forKey: .height)
        bloomSeason = try? c.decodeIfPresent(String.self, forKey: .bloomSeason)
        careTips = (try? c.decodeIfPresent([String].self, forKey: .careTips)) ?? []
        let imageText: String? = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
        imageUrl = imageText.flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case name, scientificName, reason, sun, water, careLevel, petSafe, hardiness, height, bloomSeason, careTips, imageUrl
    }
}
