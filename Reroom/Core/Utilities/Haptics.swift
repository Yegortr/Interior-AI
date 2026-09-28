import UIKit

/// Centralised haptics so every interaction uses the same vocabulary.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    /// Segmented controls, tabs, chips.
    static func tap() { light.impactOccurred() }
    /// Drawer / sheet detent snaps, drag thresholds.
    static func snap() { medium.impactOccurred() }
    /// Favorite toggles.
    static func impact() { heavy.impactOccurred() }
    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error() { notification.notificationOccurred(.error) }
    static func selection() { selectionGenerator.selectionChanged() }

    static func prepare() {
        light.prepare()
        medium.prepare()
    }
}
