import PhotosUI
import SwiftUI

/// A user photo that's been downscaled and JPEG-encoded, ready to upload.
struct PickedPhoto: Identifiable, Equatable {
    let id = UUID()
    let preview: UIImage
    let prepared: ImageProcessing.PreparedImage

    var aspectRatio: AspectRatio? { prepared.aspectRatio }

    static func == (lhs: PickedPhoto, rhs: PickedPhoto) -> Bool { lhs.id == rhs.id }

    static func load(from item: PhotosPickerItem) async -> PickedPhoto? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await make(from: data)
    }

    static func make(from image: UIImage) async -> PickedPhoto? {
        let prepared = await Task.detached(priority: .userInitiated) {
            ImageProcessing.prepareForUpload(image: image)
        }.value
        return prepared.flatMap(make(prepared:))
    }

    private static func make(from data: Data) async -> PickedPhoto? {
        let prepared = await Task.detached(priority: .userInitiated) {
            ImageProcessing.prepareForUpload(data: data)
        }.value
        return prepared.flatMap(make(prepared:))
    }

    private static func make(prepared: ImageProcessing.PreparedImage) -> PickedPhoto? {
        guard let preview = UIImage(data: prepared.data) else { return nil }
        return PickedPhoto(preview: preview, prepared: prepared)
    }
}

/// Photo picking as native Form rows: preview, "Choose from Library" and "Take Photo".
///
/// Modifiers are attached to individual rows, never to the `Section`: SwiftUI applies Section
/// modifiers to every row, which would duplicate change handlers and presentations.
struct PhotoSection: View {
    @Binding var photo: PickedPhoto?
    let footer: String

    @State private var libraryItem: PhotosPickerItem?
    @State private var isLoading = false

    var body: some View {
        Section {
            if let photo {
                Image(uiImage: photo.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
                HStack {
                    Label(photo == nil ? "Choose from Library" : "Choose Another Photo", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    if isLoading { ProgressView() }
                }
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    isLoading = true
                    defer { isLoading = false; libraryItem = nil }
                    if let picked = await PickedPhoto.load(from: item) {
                        withAnimation(.smooth) { photo = picked }
                    }
                }
            }
            .sensoryFeedback(.success, trigger: photo?.id)

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    CameraPresenter.shared.present { image in
                        Task {
                            isLoading = true
                            defer { isLoading = false }
                            if let picked = await PickedPhoto.make(from: image) {
                                withAnimation(.smooth) { photo = picked }
                            }
                        }
                    }
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } footer: {
            Text(footer)
        }
    }
}

/// Presents the system camera modally from the top-most view controller and dismisses only
/// itself — independent of SwiftUI presentation state, so it can never close the flow behind it.
@MainActor
final class CameraPresenter: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    static let shared = CameraPresenter()

    private var onCapture: ((UIImage) -> Void)?

    func present(onCapture: @escaping (UIImage) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), let presenter = Self.topViewController() else { return }
        self.onCapture = onCapture
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        let handler = onCapture
        onCapture = nil
        picker.dismiss(animated: true) {
            if let image { handler?(image) }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onCapture = nil
        picker.dismiss(animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
