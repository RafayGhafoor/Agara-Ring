import SwiftUI
import UIKit

/// The one gate for everything that needs the device camera (`UIImagePickerController` capture, the VisionKit
/// barcode scanner). The store release has NO camera use, so it ships without `NSCameraUsageDescription` and
/// the camera code below is compiled out: presenting it without the string would crash the app. Building
/// with `AGARA_CAMERA` (a Swift compilation condition nothing defines today) brings the camera back, and the
/// Info.plist string must come back with it (`PermissionDeclarationsTests` enforces the pairing).
enum CameraSupport {
    #if AGARA_CAMERA
    /// Whether a hardware camera is available (false on most simulators).
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    #else
    static var isAvailable: Bool { false }
    #endif
    static var barcodeScanningAvailable: Bool { isAvailable }
}

#if AGARA_CAMERA
/// Thin SwiftUI wrapper over `UIImagePickerController` for the device camera.
/// SwiftUI's `PhotosPicker` covers the photo library, but it can't capture from
/// the camera, so this handles that one case. Returns the picked `UIImage` via
/// `onPick` and dismisses itself.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Last line of defence: `.camera` without hardware throws, so any caller that forgot the
        // availability check gets the photo library instead of a crash.
        picker.sourceType = Self.route(cameraAvailable: CameraSupport.isAvailable) == .camera
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#else
/// Camera compiled out: callers route to the photo library (`CameraPicker.route`), so this is never presented.
struct CameraPicker: View {
    var onPick: (UIImage) -> Void
    var body: some View { EmptyView() }
}
#endif

extension CameraPicker {
    enum Route: Equatable { case camera, library }
    /// Where a "Camera" tap goes: the camera when the device has one, else the photo library
    /// (presenting the camera source without hardware throws `NSInvalidArgumentException`).
    static func route(cameraAvailable: Bool) -> Route { cameraAvailable ? .camera : .library }
}
