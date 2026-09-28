import SwiftData
import XCTest
@testable import Reroom

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

actor MockGenerationAPI: GenerationAPI {
    private(set) var uploads = 0
    private(set) var requests: [GenerationRequest] = []
    private(set) var polledIds: [[UUID]] = []
    private var rows: [UUID: JobRow] = [:]
    private var startError: Error?
    private var downloadData = Data()

    func setStartError(_ error: Error?) { startError = error }
    func setDownload(_ data: Data) { downloadData = data }
    func setRow(_ id: UUID, _ status: JobStatus, url: URL? = nil, error: String? = nil, plants: [Plant]? = nil, notes: String? = nil) {
        rows[id] = JobRow(id: id, status: status, resultUrl: url, errorMessage: error, plants: plants, designNotes: notes)
    }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        uploads += 1
        return "user/\(uploads).jpg"
    }

    func start(_ request: GenerationRequest) async throws -> UUID {
        if let startError { throw startError }
        requests.append(request)
        let id = UUID()
        rows[id] = JobRow(id: id, status: .queued)
        return id
    }

    func jobs(ids: [UUID]) async throws -> [JobRow] {
        polledIds.append(ids)
        return ids.compactMap { rows[$0] }
    }

    func download(_ url: URL) async throws -> Data { downloadData }
}

struct Boom: LocalizedError { var errorDescription: String? { "Boom" } }

@MainActor
final class GenerationCoordinatorTests: XCTestCase {
    private var container: ModelContainer!
    private var api: MockGenerationAPI!
    private var clock: TestClock!

    override func setUp() async throws {
        let schema = Schema([Design.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        api = MockGenerationAPI()
        clock = TestClock()
    }

    private func makeCoordinator(interval: Duration = .seconds(3600)) -> GenerationCoordinator {
        let clock = clock!
        return GenerationCoordinator(api: api, context: container.mainContext, pollingInterval: interval, softTimeout: 240, hardTimeout: 600, now: { clock.now })
    }

    private func photo(width: Int = 3000, height: Int = 4000) -> ImageProcessing.PreparedImage {
        ImageProcessing.PreparedImage(data: Data([1, 2, 3]), pixelSize: CGSize(width: width, height: height))
    }

    /// Inserts a design and waits for its submission to finish.
    private func submitted(_ coordinator: GenerationCoordinator) async -> Design {
        let design = Design(roomType: .bedroom, style: .japandi, notes: "", originalImageData: Data([1]), aspectRatio: AspectRatio(width: 3, height: 4))
        design.prompt = "p"
        container.mainContext.insert(design)
        await coordinator.submit(design)
        return design
    }

    func testCreateShowsImmediatelyWithPhotoRatioAndPrompt() {
        let coordinator = makeCoordinator()
        let design = coordinator.create(roomType: .kitchen, style: .scandinavian, notes: "keep the island", photo: photo())
        XCTAssertEqual(design.status, .submitting)
        XCTAssertEqual(design.aspectRatio, AspectRatio(width: 3, height: 4))
        XCTAssertTrue(design.prompt.contains("kitchen"))
        XCTAssertTrue(design.prompt.contains("Scandinavian"))
        XCTAssertTrue(design.prompt.contains("keep the island"))
        let stored = try? container.mainContext.fetch(FetchDescriptor<Design>())
        XCTAssertEqual(stored?.count, 1)
    }

    func testSubmitUploadsAndQueues() async {
        let coordinator = makeCoordinator()
        let design = await submitted(coordinator)
        XCTAssertEqual(design.status, .queued)
        XCTAssertNotNil(design.jobId)
        XCTAssertEqual(design.submittedAt, clock.now)
        let requests = await api.requests
        XCTAssertEqual(requests.first?.imagePath, "user/1.jpg")
        XCTAssertEqual(requests.first?.aspectRatio, "3:4")
        XCTAssertEqual(requests.first?.clientRequestId, design.id)
    }

    func testSubmitFailureIsRetryable() async {
        await api.setStartError(Boom())
        let coordinator = makeCoordinator()
        let design = await submitted(coordinator)
        XCTAssertEqual(design.status, .failed)
        XCTAssertEqual(design.errorMessage, "Boom")
        XCTAssertTrue(design.isRetryable)
    }

    func testProcessingThenCompletedStoresResultAndRealRatio() async throws {
        let coordinator = makeCoordinator()
        let design = await submitted(coordinator)
        let jobId = try XCTUnwrap(design.jobId)

        await api.setRow(jobId, .processing)
        await coordinator.pollOnce()
        XCTAssertEqual(design.status, .generating)

        let result = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { _ in }.jpegData(compressionQuality: 0.8))
        await api.setDownload(result)
        await api.setRow(jobId, .completed, url: URL(string: "https://im.example.com/r.jpg"))
        await coordinator.pollOnce()

        XCTAssertEqual(design.status, .completed)
        XCTAssertEqual(design.resultImageData, result)
        XCTAssertTrue(design.aspectRatio.isLandscape, "Ratio should follow the real result")
    }

    func testServerFailureCarriesMessage() async throws {
        let coordinator = makeCoordinator()
        let design = await submitted(coordinator)
        await api.setRow(try XCTUnwrap(design.jobId), .failed, error: "Content not allowed")
        await coordinator.pollOnce()
        XCTAssertEqual(design.status, .failed)
        XCTAssertEqual(design.errorMessage, "Content not allowed")
    }

    func testSoftThenHardTimeout() async {
        let coordinator = makeCoordinator()
        let design = await submitted(coordinator)
        clock.now += 241
        await coordinator.pollOnce()
        XCTAssertEqual(design.status, .stale)
        XCTAssertTrue(design.isRetryable)
        clock.now += 400
        await coordinator.pollOnce()
        XCTAssertEqual(design.status, .failed)
    }

    func testPollsOnlyPendingJobs() async throws {
        let coordinator = makeCoordinator()
        let first = await submitted(coordinator)
        let second = await submitted(coordinator)
        await api.setRow(try XCTUnwrap(first.jobId), .failed)
        await coordinator.pollOnce()
        await coordinator.pollOnce()
        let polled = await api.polledIds
        XCTAssertEqual(Set(polled[0]), Set([first.jobId!, second.jobId!]))
        XCTAssertEqual(polled[1], [second.jobId!])
    }

    func testResumeFailsInterruptedSubmissions() {
        let design = Design(roomType: .bedroom, style: .modern, notes: "", originalImageData: Data([1]), aspectRatio: .square)
        container.mainContext.insert(design)
        makeCoordinator().resume()
        XCTAssertEqual(design.status, .failed)
        XCTAssertNotNil(design.errorMessage)
    }

    func testMakeChangesUsesResultAsSource() async {
        let coordinator = makeCoordinator()
        let source = await submitted(coordinator)
        source.resultImageData = Data([9, 9])
        source.status = .completed
        let edit = coordinator.makeChanges(from: source, change: "add plants")
        XCTAssertEqual(edit?.originalImageData, Data([9, 9]))
        XCTAssertEqual(edit?.parentId, source.id)
        XCTAssertTrue(edit?.prompt.contains("add plants") == true)
    }

    private func gardenContext() -> GardenContext {
        GardenContext(
            location: GardenLocation(name: "Lisbon, Portugal", latitude: 38.7223, longitude: -9.1393),
            month: 4, sunlight: .fullSun, style: .mediterranean, maintenance: .low,
            petSafe: true, hardscaping: [.patio], notes: "keep the lemon tree"
        )
    }

    func testGardenSendsContextAndStoresPlantsBeforeImage() async throws {
        let coordinator = makeCoordinator()
        let design = coordinator.createGarden(gardenContext(), photo: photo(width: 4000, height: 3000))
        XCTAssertEqual(design.kind, .garden)
        XCTAssertEqual(design.locationName, "Lisbon, Portugal")
        XCTAssertEqual(design.gardenContext?.location.latitude, 38.7, "Coordinates are coarsened")
        await coordinator.submit(design)

        let request = try XCTUnwrap(await api.requests.last)
        XCTAssertEqual(request.kind, .garden)
        XCTAssertEqual(request.garden?.style, .mediterranean)
        XCTAssertTrue(request.garden?.petSafe == true)

        let lavender = Plant(name: "Lavender", scientificName: "Lavandula stoechas", petSafe: true, careTips: ["Prune after flowering"])
        await api.setRow(try XCTUnwrap(design.jobId), .processing, plants: [lavender], notes: "Drought-tolerant planting")
        await coordinator.pollOnce()
        XCTAssertEqual(design.plants, [lavender])
        XCTAssertEqual(design.designNotes, "Drought-tolerant planting")
        XCTAssertEqual(design.status, .generating)
    }

    func testEditOfGardenKeepsPlantsAndDoesNotRequestNewOnes() async throws {
        let coordinator = makeCoordinator()
        let source = coordinator.createGarden(gardenContext(), photo: photo())
        source.plants = [Plant(name: "Olive")]
        source.resultImageData = Data([7])
        source.status = .completed
        let edit = try XCTUnwrap(coordinator.makeChanges(from: source, change: "add a bench"))
        XCTAssertEqual(edit.kind, .garden)
        XCTAssertEqual(edit.plants.map(\.name), ["Olive"])
        await coordinator.submit(edit)
        let request = try XCTUnwrap(await api.requests.last)
        XCTAssertNil(request.garden)
    }

    func testPollingStopsWhenNothingPending() async throws {
        let coordinator = makeCoordinator(interval: .milliseconds(20))
        let design = await submitted(coordinator)
        XCTAssertTrue(coordinator.isPolling)
        await api.setDownload(Data([1]))
        await api.setRow(try XCTUnwrap(design.jobId), .completed, url: URL(string: "https://x.com/a.jpg"))
        for _ in 0..<100 where coordinator.isPolling {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(coordinator.isPolling)
        XCTAssertEqual(design.status, .completed)
    }
}

final class PureLogicTests: XCTestCase {
    func testPromptKeepsGeometryAndAddsWishes() {
        let prompt = PromptBuilder.redesign(room: .livingRoom, style: .japandi, notes: " keep the fireplace. ")
        XCTAssertTrue(prompt.contains("living room"))
        XCTAssertTrue(prompt.contains("Japandi"))
        XCTAssertTrue(prompt.contains("Also: keep the fireplace."))
        XCTAssertTrue(prompt.contains(PromptBuilder.preserveGeometry))
    }

    func testEditPrompt() {
        let prompt = PromptBuilder.edit(change: "add plants")
        XCTAssertTrue(prompt.hasPrefix("Edit this interior photo: add plants."))
    }

    func testOutputSizeMatchesRatioInMultiplesOf64() {
        for ratio in [AspectRatio.portrait, .landscape, .square, AspectRatio(width: 3, height: 4), AspectRatio(width: 4, height: 3)] {
            let size = OutputSize.pixels(for: ratio)
            XCTAssertEqual(size.width % 64, 0)
            XCTAssertEqual(size.height % 64, 0)
            XCTAssertEqual(max(size.width, size.height), OutputSize.longEdge)
            XCTAssertEqual(size.width > size.height, ratio.isLandscape)
        }
    }

    func testAspectRatioParsing() {
        XCTAssertEqual(AspectRatio(pixelWidth: 4032, pixelHeight: 3024)?.stringValue, "4:3")
        XCTAssertEqual(AspectRatio(string: "9:16"), .portrait)
    }

    func testGardenPrompt() {
        let context = GardenContext(
            location: GardenLocation(name: "Austin, Texas"), month: 6, sunlight: .partialSun, style: .desert,
            maintenance: .low, petSafe: true, hardscaping: [.pathway, .firePit], notes: ""
        )
        let prompt = PromptBuilder.garden(context)
        XCTAssertTrue(prompt.contains("Desert garden"))
        XCTAssertTrue(prompt.contains("Austin, Texas"))
        XCTAssertTrue(prompt.contains("pathway, fire pit"))
        XCTAssertTrue(prompt.contains("safe for cats and dogs"))
    }

    func testJobRowWithPlantsIsLenient() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","status":"processing","plants":[{"name":"Rosemary","petSafe":true,"careTips":["Full sun"]},{"noName":true},{"name":"Agave","careTips":null,"imageUrl":"https://x.supabase.co/p/agave.jpg"}],"design_notes":"Dry garden"}]"#
        let row = try XCTUnwrap(try JSONDecoder().decode([JobRow].self, from: Data(json.utf8)).first)
        XCTAssertEqual(row.plants?.map(\.name), ["Rosemary", "Agave"])
        XCTAssertEqual(row.plants?.last?.careTips, [])
        XCTAssertEqual(row.plants?.last?.imageUrl?.lastPathComponent, "agave.jpg")
        XCTAssertEqual(row.designNotes, "Dry garden")
    }

    func testJobRowDecoding() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString.lowercased())","status":"completed","result_url":"https://im.runware.ai/a.jpg","error_message":null},{"id":"\#(UUID().uuidString)","status":"weird"}]"#
        let rows = try JSONDecoder().decode([JobRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].status, .completed)
        XCTAssertEqual(rows[0].resultUrl?.host, "im.runware.ai")
        XCTAssertEqual(rows[1].status, .unknown)
    }
}
