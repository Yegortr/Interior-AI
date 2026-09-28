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
    var kind: DesignKind = .interior
    /// Garden answers; the server uses them to pick regional plants before rendering.
    var garden: GardenContext?
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
    /// Garden jobs: plants picked for the user's region (may arrive before the image).
    let plants: [Plant]?
    let designNotes: String?

    init(id: UUID, status: JobStatus, resultUrl: URL? = nil, errorMessage: String? = nil, plants: [Plant]? = nil, designNotes: String? = nil) {
        self.id = id
        self.status = status
        self.resultUrl = resultUrl
        self.errorMessage = errorMessage
        self.plants = plants
        self.designNotes = designNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        status = (try? c.decode(JobStatus.self, forKey: .status)) ?? .unknown
        resultUrl = (try? c.decodeIfPresent(String.self, forKey: .resultUrl)).flatMap(URL.init(string:))
        errorMessage = try? c.decodeIfPresent(String.self, forKey: .errorMessage)
        plants = (try? c.decodeIfPresent([LossyPlant].self, forKey: .plants))?.compactMap(\.plant)
        designNotes = try? c.decodeIfPresent(String.self, forKey: .designNotes)
    }

    enum CodingKeys: String, CodingKey {
        case id, status, plants
        case resultUrl = "result_url"
        case errorMessage = "error_message"
        case designNotes = "design_notes"
    }

    private struct LossyPlant: Decodable {
        let plant: Plant?
        init(from decoder: Decoder) throws { plant = try? Plant(from: decoder) }
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
            .select("id,status,result_url,error_message,plants,design_notes")
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
