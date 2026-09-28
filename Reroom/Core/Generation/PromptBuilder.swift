import Foundation

/// Builds the image-model prompts. Kept pure so it's easy to test and tune.
enum PromptBuilder {
    static let preserveGeometry = "Keep the exact room geometry, walls, windows, doors, ceiling and camera angle unchanged."
    static let quality = "Photorealistic interior design photography, natural daylight, high detail. No text, no watermark."

    static func redesign(room: RoomType, style: InteriorStyle, notes: String) -> String {
        var parts = [
            "Redesign this \(room.title.lowercased()) in \(style.title) interior style: \(style.promptDetails).",
            preserveGeometry,
        ]
        let wishes = clean(notes)
        if !wishes.isEmpty { parts.append("Also: \(wishes).") }
        parts.append(quality)
        return parts.joined(separator: " ")
    }

    /// "Make Changes": edit an existing result, touching only what was asked.
    static func edit(change: String) -> String {
        "Edit this interior photo: \(clean(change)). Change only that and keep everything else, including layout, furniture, lighting and camera angle, exactly the same. \(quality)"
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
