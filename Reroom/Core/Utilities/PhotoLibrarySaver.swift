import Photos
import UIKit

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            "DreamStroke doesn't have permission to add photos. You can allow it in Settings › Privacy › Photos."
        }
    }

    /// Saves the original bytes (keeps full resolution & metadata) to the user's library.
    static func save(imageData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.permissionDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: imageData, options: nil)
        }
    }
}
