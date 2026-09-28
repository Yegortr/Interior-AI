import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)

    static let placeholderGradient = LinearGradient(
        colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.06)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    /// `#RRGGBB` / `RRGGBB` → Color. Returns nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Large, full-width call-to-action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Subtle press feedback for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
