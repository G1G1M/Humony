import SwiftUI
import UIKit

/// 악보를 그 자리에서 찍기 위한 카메라 시트 (156절).
///
/// SwiftUI에는 카메라 촬영용 네이티브 뷰가 없어서 `UIImagePickerController`를 감싼다
/// (사진 **앨범**은 `PhotosPicker`가 네이티브로 있어서 그쪽을 쓴다).
struct CameraPicker: UIViewControllerRepresentable {

    /// 찍은 사진을 JPEG 데이터로 넘긴다 — `CGImage`를 그대로 넘기면 백그라운드로 보낼 때
    /// 동시성 규칙에 걸리고, 어차피 해독하는 쪽에서 다시 디코드한다.
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    /// 카메라를 쓸 수 없는 환경(시뮬레이터)에서는 촬영 메뉴를 감춘다.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // 압축률을 높게 두는 이유: 오선 줄은 얇아서 JPEG 아티팩트에 쉽게 뭉개진다.
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.95) else {
                onCancel()
                return
            }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
