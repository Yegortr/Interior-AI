import Foundation
import Supabase

enum SupabaseService {
    static let client = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey.isEmpty ? "missing-anon-key" : AppConfig.supabaseAnonKey
    )
}

/// There is no sign-in screen: every install gets an invisible anonymous Supabase user so the
/// backend can apply per-user limits and row-level security. The session lives in the Keychain.
enum AnonymousAuth {
    static func userId() async throws -> UUID {
        let auth = SupabaseService.client.auth
        if let session = try? await auth.session { return session.user.id }
        return try await auth.signInAnonymously().user.id
    }
}

extension UUID {
    /// Postgres prints UUIDs in lowercase; match it in filters and storage paths.
    var dbString: String { uuidString.lowercased() }
}

enum APIError: LocalizedError {
    case notConfigured
    case invalidResponse(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The app isn't connected to its server yet."
        case .invalidResponse(let detail): "Unexpected server response. \(detail)"
        case .server(let message): message
        }
    }

    static func message(for error: Error) -> String {
        if let functionsError = error as? FunctionsError, case .httpError(let code, let data) = functionsError {
            struct Body: Decodable { let error: String? }
            if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error { return message }
            return "The server returned an error (\(code))."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You appear to be offline."
            case .timedOut: return "The request timed out."
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
