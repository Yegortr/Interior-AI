import Foundation

/// Static configuration resolved from Info.plist (populated by `Config/App.xcconfig`).
enum AppConfig {
    static let supabaseURL: URL = {
        if let raw = infoString("SUPABASE_URL"), let url = URL(string: raw), url.host != nil { return url }
        return URL(string: "https://your-project.supabase.co")!
    }()

    static let supabaseAnonKey: String = infoString("SUPABASE_ANON_KEY") ?? ""

    static var isConfigured: Bool {
        !supabaseAnonKey.isEmpty && supabaseURL.host != "your-project.supabase.co"
    }

    /// Storage bucket for the user's original photos (temporary; the server only needs them while generating).
    static let uploadsBucket = "uploads"

    static let pollingInterval: Duration = .seconds(4)
    /// After this long a generation is marked `stale` (still polled, retry offered).
    static let softTimeout: TimeInterval = 4 * 60
    /// After this long a generation is marked `failed`.
    static let hardTimeout: TimeInterval = 10 * 60

    /// Long edge (px) photos are downscaled to before upload.
    static let uploadMaxDimension: CGFloat = 2048

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}
