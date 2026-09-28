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
    func setRow(_ id: UUID, _ status: JobStatus, url: URL? = nil, error: String? = nil) {
        rows[id] = JobRow(id: id, status: status, resultUrl: url, errorMessage: error)
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
