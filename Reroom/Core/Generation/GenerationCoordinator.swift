import Foundation
import Observation
import SwiftData

/// Drives every design from "Generate" to a finished image stored on the device.
///
/// State lives on the `Design` models themselves (SwiftData), so it survives relaunches and
/// syncs through iCloud. While — and only while — something is pending, the coordinator polls
/// `generation_jobs` for exactly those ids; results are downloaded and stored locally.
@Observable
@MainActor
final class GenerationCoordinator {
    private(set) var isPolling = false

    @ObservationIgnored private let api: GenerationAPI
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let softTimeout: TimeInterval
    @ObservationIgnored private let hardTimeout: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isPollingOnce = false

    init(
        api: GenerationAPI,
        context: ModelContext,
        pollingInterval: Duration = AppConfig.pollingInterval,
        softTimeout: TimeInterval = AppConfig.softTimeout,
        hardTimeout: TimeInterval = AppConfig.hardTimeout,
        now: @escaping () -> Date = { Date() }
    ) {
        self.api = api
        self.context = context
        self.pollingInterval = pollingInterval
        self.softTimeout = softTimeout
        self.hardTimeout = hardTimeout
        self.now = now
    }

    // MARK: Commands

    /// Creates the design immediately (so its placeholder shows at once) and submits it.
    @discardableResult
    func create(roomType: RoomType, style: InteriorStyle, notes: String, photo: ImageProcessing.PreparedImage) -> Design {
        let design = Design(
            roomType: roomType, style: style, notes: notes,
            originalImageData: photo.data, aspectRatio: photo.aspectRatio ?? .gridCard
        )
        design.prompt = PromptBuilder.redesign(room: roomType, style: style, notes: notes)
        insertAndSubmit(design)
        return design
    }

    /// A garden: the server first picks plants that thrive in the user's region, then renders.
    @discardableResult
    func createGarden(_ context: GardenContext, photo: ImageProcessing.PreparedImage) -> Design {
        let design = Design.garden(context, originalImageData: photo.data, aspectRatio: photo.aspectRatio ?? .gridCard)
        design.prompt = PromptBuilder.garden(context)
        insertAndSubmit(design)
        return design
    }

    /// "Make Changes": a new design whose source photo is the previous result.
    @discardableResult
    func makeChanges(from source: Design, change: String) -> Design? {
        guard let resultData = source.resultImageData else { return nil }
        let design = Design(
            roomType: source.roomType, style: source.style, notes: change,
            originalImageData: resultData, aspectRatio: source.aspectRatio
        )
        design.parentId = source.id
        design.kindRaw = source.kindRaw
        design.gardenStyleRaw = source.gardenStyleRaw
        design.locationName = source.locationName
        // Keep the plant list: an edit changes the picture, not the recommendations.
        design.plantsData = source.plantsData
        design.designNotes = source.designNotes
        design.prompt = PromptBuilder.edit(change: change)
        insertAndSubmit(design)
        return design
    }

    func retry(_ design: Design) {
        guard design.isRetryable else { return }
        design.jobId = nil
        design.submittedAt = nil
        design.errorMessage = nil
        design.status = .submitting
        save()
        Task { await submit(design) }
    }

    func delete(_ design: Design) {
        context.delete(design)
        save()
    }

    /// Call at launch: repairs interrupted submissions and resumes polling.
    func resume() {
        let submitting = DesignStatus.submitting.rawValue
        let stuck = (try? context.fetch(FetchDescriptor<Design>(predicate: #Predicate<Design> { $0.statusRaw == submitting }))) ?? []
        for design in stuck where design.jobId == nil {
            design.errorMessage = "Interrupted before it reached the server."
            design.status = .failed
        }
        save()
        startPollingIfNeeded()
    }

    /// Poll right away (e.g. back from background) and keep polling if needed.
    func refreshNow() async {
        await pollOnce()
        startPollingIfNeeded()
    }

    // MARK: Submission

    func submit(_ design: Design) async {
        guard let photo = design.originalImageData else {
            fail(design, "The original photo is missing.")
            return
        }
        do {
            let path = try await api.uploadPhoto(photo)
            let size = OutputSize.pixels(for: design.aspectRatio)
            let request = GenerationRequest(
                imagePath: path,
                prompt: design.prompt,
                aspectRatio: design.aspectRatio.stringValue,
                width: size.width,
                height: size.height,
                clientRequestId: design.id,
                kind: design.kind,
                // Edits reuse the source's plants; only fresh gardens ask for new ones.
                garden: design.parentId == nil ? design.gardenContext : nil
            )
            let jobId = try await api.start(request)
            guard !design.isDeleted else { return }
            design.jobId = jobId
            design.submittedAt = now()
            design.status = .queued
            save()
            startPollingIfNeeded()
        } catch {
            fail(design, APIError.message(for: error))
        }
    }

    // MARK: Polling

    func startPollingIfNeeded() {
        guard pollTask == nil, !pendingDesigns().isEmpty else { return }
        isPolling = true
        pollTask = Task { [weak self, pollingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollingInterval)
                guard let self, !Task.isCancelled else { return }
                await self.pollOnce()
                if self.pendingDesigns().isEmpty { break }
            }
            self?.pollTask = nil
            self?.isPolling = false
        }
    }

    func pollOnce() async {
        guard !isPollingOnce else { return }
        isPollingOnce = true
        defer { isPollingOnce = false }

        let ids = pendingDesigns().compactMap(\.jobId)
        var rows: [UUID: JobRow] = [:]
        if !ids.isEmpty, let fetched = try? await api.jobs(ids: ids) {
            rows = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // Re-fetch after the await: designs may have been deleted or retried meanwhile.
        for design in pendingDesigns() {
            if let jobId = design.jobId, let row = rows[jobId] {
                await apply(row, to: design)
            }
            applyTimeouts(to: design)
        }
        save()
    }

    // MARK: Private

    private func insertAndSubmit(_ design: Design) {
        context.insert(design)
        save()
        Task { await submit(design) }
    }

    private func apply(_ row: JobRow, to design: Design) async {
        if let plants = row.plants, !plants.isEmpty, plants != design.plants {
            design.plants = plants
        }
        if let notes = row.designNotes, !notes.isEmpty, notes != design.designNotes {
            design.designNotes = notes
        }
        switch row.status {
        case .queued, .unknown:
            break
        case .processing:
            if design.status == .queued { design.status = .generating }
        case .failed:
            fail(design, row.errorMessage ?? "Generation failed. Please try again.")
        case .completed:
            guard let url = row.resultUrl else {
                fail(design, "The server returned no image.")
                return
            }
            // A failed download is simply retried on the next poll.
            guard let data = try? await api.download(url) else { return }
            guard !design.isDeleted, design.status.isPending else { return }
            design.resultImageData = data
            if let size = ImageProcessing.pixelSize(of: data), let ratio = AspectRatio(size: size) {
                design.aspectWidth = ratio.width
                design.aspectHeight = ratio.height
            }
            design.errorMessage = nil
            design.status = .completed
        }
    }

    private func applyTimeouts(to design: Design) {
        guard !design.isDeleted, design.status.isPending else { return }
        let age = now().timeIntervalSince(design.submittedAt ?? design.createdAt)
        if age >= hardTimeout {
            fail(design, "This took too long. Please try again.")
        } else if age >= softTimeout, design.status != .stale {
            design.status = .stale
        }
    }

    private func fail(_ design: Design, _ message: String) {
        guard !design.isDeleted else { return }
        design.errorMessage = message
        design.status = .failed
        save()
    }

    private func pendingDesigns() -> [Design] {
        let queued = DesignStatus.queued.rawValue
        let generating = DesignStatus.generating.rawValue
        let stale = DesignStatus.stale.rawValue
        let descriptor = FetchDescriptor<Design>(predicate: #Predicate<Design> {
            $0.statusRaw == queued || $0.statusRaw == generating || $0.statusRaw == stale
        })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func save() {
        try? context.save()
    }
}
