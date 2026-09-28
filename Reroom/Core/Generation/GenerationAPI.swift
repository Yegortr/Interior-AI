import Foundation
import Supabase

/// Body of the `generate` edge function.
struct GenerationRequest: Codable, Hashable, Sendable {
    /// Storage path of the uploaded source photo (`<user id>/<file>.jpg`).
    var imagePath: String
    var prompt: String
    var aspectRatio: String
    var width: Int
    var height: Int
    /// Local design id, for idempotency and debugging.
    var clientRequestId: UUID
}

/// `generation_jobs` status as written by the server.
enum JobStatus: String, Decodable, Sendable {
    case queued, processing, completed, failed, unknown

    init(from decoder: Decoder) throws {
        self = JobStatus(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

struct JobRow: Decodable, Hashable, Sendable {
    let id: UUID
    let status: JobStatus
    let resultUrl: URL?
    let errorMessage: String?

    init(id: UUID, status: JobStatus, resultUrl: URL? = nil, errorMessage: String? = nil) {
        self.id = id
        self.status = status
        self.resultUrl = resultUrl
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case resultUrl = "result_url"
        case errorMessage = "error_message"
    }
}

/// Everything the generation flow needs from the network; abstracted for tests.
protocol GenerationAPI: Sendable {
    /// Uploads the source photo and returns its storage path.
    func uploadPhoto(_ jpeg: Data) async throws -> String
    /// Starts a generation and returns the job id.
    func start(_ request: GenerationRequest) async throws -> UUID
    /// Targeted poll for exactly these jobs.
    func jobs(ids: [UUID]) async throws -> [JobRow]
    func download(_ url: URL) async throws -> Data
}

struct SupabaseGenerationAPI: GenerationAPI {
    private var client: SupabaseClient { SupabaseService.client }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        guard AppConfig.isConfigured else { throw APIError.notConfigured }
        let userId = try await AnonymousAuth.userId()
        let path = "\(userId.dbString)/\(UUID().dbString).jpg"
        _ = try await client.storage
            .from(AppConfig.uploadsBucket)
            .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    func start(_ request: GenerationRequest) async throws -> UUID {
        _ = try await AnonymousAuth.userId()
        let response: StartResponse = try await client.functions.invoke(
            "generate",
            options: FunctionInvokeOptions(body: request)
        )
        return response.jobId
    }

    func jobs(ids: [UUID]) async throws -> [JobRow] {
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("generation_jobs")
            .select("id,status,result_url,error_message")
            .in("id", values: ids.map(\.dbString))
            .execute()
            .value
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private struct StartResponse: Decodable {
        let jobId: UUID
    }
}
