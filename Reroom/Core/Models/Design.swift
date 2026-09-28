import Foundation
import SwiftData

enum DesignStatus: String, Codable, Sendable {
    /// Photo is being uploaded / request is being sent.
    case submitting
    case queued
    case generating
    case completed
    case failed
    /// Soft timeout exceeded; still polled until the hard timeout, retry offered.
    case stale

    /// Still needs polling.
    var isPending: Bool {
        switch self {
        case .queued, .generating, .stale: true
        case .submitting, .completed, .failed: false
        }
    }

    var isInProgress: Bool { self == .submitting || isPending }
}

/// One redesign: the user's photo, the choices they made and (once ready) the result.
///
/// Stored with SwiftData and mirrored to the user's private iCloud database, so every property
/// has a default and there are no unique constraints (CloudKit requirements).
@Model
final class Design {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var roomTypeRaw: String = RoomType.livingRoom.rawValue
    var styleRaw: String = InteriorStyle.modern.rawValue
    /// Free-form wishes ("keep the fireplace") or, for edits, the requested change.
    var notes: String = ""
    /// The full prompt sent to the model.
    var prompt: String = ""

    /// Expected output ratio (the photo's), refined to the real result once it arrives.
    var aspectWidth: Double = 3
    var aspectHeight: Double = 4

    var statusRaw: String = DesignStatus.submitting.rawValue
    var jobId: UUID?
    var submittedAt: Date?
    var errorMessage: String?
    var isFavorite: Bool = false
    /// Set when this design was made with "Make Changes" from another one.
    var parentId: UUID?

    @Attribute(.externalStorage) var originalImageData: Data?
    @Attribute(.externalStorage) var resultImageData: Data?

    init(roomType: RoomType, style: InteriorStyle, notes: String, originalImageData: Data, aspectRatio: AspectRatio) {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
        self.roomTypeRaw = roomType.rawValue
        self.styleRaw = style.rawValue
        self.notes = notes
        self.originalImageData = originalImageData
        self.aspectWidth = aspectRatio.width
        self.aspectHeight = aspectRatio.height
        self.statusRaw = DesignStatus.submitting.rawValue
    }

    var status: DesignStatus {
        get { DesignStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }

    var roomType: RoomType { RoomType(rawValue: roomTypeRaw) ?? .livingRoom }
    var style: InteriorStyle { InteriorStyle(rawValue: styleRaw) ?? .modern }

    var aspectRatio: AspectRatio {
        guard aspectWidth > 0, aspectHeight > 0 else { return .gridCard }
        return AspectRatio(width: aspectWidth, height: aspectHeight)
    }

    var isRetryable: Bool { status == .failed || status == .stale }
}
