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

/// Single-photo input (garden / room photo) with camera and library sources.
struct SinglePhotoInput: View {
    @Binding var photo: PickedPhoto?
    var title = "Add a photo"
    var subtitle = "Take a photo or pick one from your library"

    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            if let photo {
                Image(uiImage: photo.preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .frame(maxHeight: 360)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            Haptics.tap()
                            withAnimation(Theme.spring) { self.photo = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Remove photo")
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else {
                VStack(spacing: 14) {
                    Image(systemName: isLoading ? "hourglass" : "photo.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse, isActive: isLoading)
                    VStack(spacing: 4) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 12) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                Haptics.tap()
                                showCamera = true
                            } label: {
                                Label("Camera", systemImage: "camera")
                            }
                            .buttonStyle(.bordered)
                        }
                        PhotosPicker(selection: $libraryItem, matching: .images) {
                            Label("Library", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                )
            }
        }
        .animation(Theme.spring, value: photo)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                isLoading = true
                defer { isLoading = false; libraryItem = nil }
                if let picked = await PickedPhoto.load(from: item) {
                    photo = picked
                }
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
