import SwiftUI

/// Renders a capture's photograph: the real file stored on the device when the capture came from
/// the native camera, and the reference image otherwise. Layout is identical in both cases, so
/// the approved gallery, card and confirmation surfaces stay exactly as designed.
struct CaptureImage: View {
    let capture: CaptureItem
    var contentMode: ContentMode = .fill

    @State private var localImage: UIImage?

    var body: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(capture.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: capture.localFile?.fileName) {
            await loadLocalFile()
        }
    }

    private func loadLocalFile() async {
        guard let file = capture.localFile else {
            localImage = nil
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            CaptureFileStore.loadData(file).flatMap { UIImage(data: $0) }
        }.value
        localImage = image
    }
}
