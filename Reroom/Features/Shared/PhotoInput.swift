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
struct PhotoSection: View {
    @Binding var photo: PickedPhoto?
    let footer: String

    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
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
                    .transition(.opacity)
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
                HStack {
                    Label(photo == nil ? "Choose from Library" : "Choose Another Photo", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    if isLoading { ProgressView() }
                }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } footer: {
            Text(footer)
        }
        .animation(.default, value: photo)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                isLoading = true
                defer { isLoading = false; libraryItem = nil }
                if let picked = await PickedPhoto.load(from: item) { photo = picked }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task {
                    isLoading = true
                    defer { isLoading = false }
                    photo = await PickedPhoto.make(from: image)
                }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.success, trigger: photo?.id)
    }
}

/// `UIImagePickerController` camera wrapper.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
