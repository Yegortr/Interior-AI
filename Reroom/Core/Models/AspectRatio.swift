import CoreGraphics
import Foundation

/// A width:height ratio. Encoded as `"W:H"` (e.g. `"16:9"`), which is also what the backend stores
/// in `generated_images.parameters.aspectRatio`.
struct AspectRatio: Hashable, Sendable {
    let width: Double
    let height: Double

    init(width: Double, height: Double) {
        precondition(width > 0 && height > 0, "Aspect ratio components must be positive")
        self.width = width
        self.height = height
    }

    static let portrait = AspectRatio(width: 9, height: 16)
    static let landscape = AspectRatio(width: 16, height: 9)
    static let square = AspectRatio(width: 1, height: 1)
    /// Fixed crop used by every card in the 2-column grid.
    static let gridCard = AspectRatio(width: 3, height: 4)

    /// Width divided by height — the value SwiftUI's `.aspectRatio(_:contentMode:)` expects.
    var value: CGFloat { CGFloat(width / height) }

    var isLandscape: Bool { width > height }
    var isPortrait: Bool { height > width }

    /// Builds a ratio from pixel dimensions, reduced by their GCD (4032×3024 → 4:3).
    init?(pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let divisor = Self.gcd(pixelWidth, pixelHeight)
        self.init(width: Double(pixelWidth / divisor), height: Double(pixelHeight / divisor))
    }

    init?(size: CGSize) {
        self.init(pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()))
    }

    /// Parses `"16:9"`, `"16x9"`, `"16/9"` or a plain decimal such as `"1.7778"`.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let separators = CharacterSet(charactersIn: ":x/×")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
            self.init(width: w, height: h)
        } else if parts.count == 1, let decimal = Double(parts[0]), decimal > 0 {
            self.init(width: decimal, height: 1)
        } else {
            return nil
        }
    }

    var stringValue: String {
        "\(Self.format(width)):\(Self.format(height))"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.4f", value)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}

extension AspectRatio: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let ratio = AspectRatio(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid aspect ratio \(raw)")
        }
        self = ratio
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
