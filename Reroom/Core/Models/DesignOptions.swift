import Foundation

enum RoomType: String, CaseIterable, Identifiable, Codable, Sendable {
    case livingRoom = "living_room", bedroom, kitchen, bathroom, diningRoom = "dining_room"
    case homeOffice = "home_office", kidsRoom = "kids_room", hallway, balcony

    var id: String { rawValue }

    var title: String {
        switch self {
        case .livingRoom: "Living Room"
        case .bedroom: "Bedroom"
        case .kitchen: "Kitchen"
        case .bathroom: "Bathroom"
        case .diningRoom: "Dining Room"
        case .homeOffice: "Home Office"
        case .kidsRoom: "Kids Room"
        case .hallway: "Hallway"
        case .balcony: "Balcony"
        }
    }

    var symbol: String {
        switch self {
        case .livingRoom: "sofa"
        case .bedroom: "bed.double"
        case .kitchen: "refrigerator"
        case .bathroom: "bathtub"
        case .diningRoom: "fork.knife"
        case .homeOffice: "desktopcomputer"
        case .kidsRoom: "teddybear"
        case .hallway: "door.left.hand.open"
        case .balcony: "sun.horizon"
        }
    }
}

enum InteriorStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case modern, scandinavian, japandi, midCentury = "mid_century", industrial
    case bohemian, minimalist, coastal, artDeco = "art_deco", farmhouse, classic, luxury

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .scandinavian: "Scandinavian"
        case .japandi: "Japandi"
        case .midCentury: "Mid-Century"
        case .industrial: "Industrial"
        case .bohemian: "Bohemian"
        case .minimalist: "Minimalist"
        case .coastal: "Coastal"
        case .artDeco: "Art Deco"
        case .farmhouse: "Farmhouse"
        case .classic: "Classic"
        case .luxury: "Luxury"
        }
    }

    /// What the style means, phrased for the image model.
    var promptDetails: String {
        switch self {
        case .modern: "clean lines, neutral palette with warm accents, sleek furniture, statement lighting"
        case .scandinavian: "light oak wood, white walls, cozy textiles, hygge atmosphere, functional furniture"
        case .japandi: "natural wood and linen, muted earthy tones, low furniture, calm minimalism, wabi-sabi details"
        case .midCentury: "walnut wood, tapered legs, organic curves, mustard and teal accents, retro lighting"
        case .industrial: "exposed brick, black steel, concrete, leather, Edison bulb pendants"
        case .bohemian: "layered rugs and textiles, rattan, plants, warm patterns, eclectic decor"
        case .minimalist: "uncluttered space, monochrome palette, hidden storage, few carefully chosen pieces"
        case .coastal: "white and sand tones, soft blues, linen, light woods, airy and bright"
        case .artDeco: "geometric patterns, brass and gold, velvet, rich jewel tones, glamorous lighting"
        case .farmhouse: "reclaimed wood, shiplap, vintage accents, warm whites, rustic charm"
        case .classic: "moldings, elegant symmetrical layout, traditional furniture, rich fabrics"
        case .luxury: "marble, premium materials, designer furniture, layered lighting, refined palette"
        }
    }

    /// Two colors used for the style tile.
    var swatch: (String, String) {
        switch self {
        case .modern: ("#D9D4CC", "#3A3A3A")
        case .scandinavian: ("#F4F1EA", "#C8A97E")
        case .japandi: ("#E6DDCF", "#7A6A58")
        case .midCentury: ("#C9822B", "#2F5D62")
        case .industrial: ("#8C8C8C", "#5A3B2E")
        case .bohemian: ("#D98E5F", "#6B8F4E")
        case .minimalist: ("#FFFFFF", "#BDBDBD")
        case .coastal: ("#F2EDE4", "#7FA7C9")
        case .artDeco: ("#1F3A4D", "#C9A227")
        case .farmhouse: ("#EDE6DA", "#8B6B4A")
        case .classic: ("#EAE0D0", "#7B2E2E")
        case .luxury: ("#F0EEEA", "#1C1C1C")
        }
    }
}
