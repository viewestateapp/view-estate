import AVFoundation
import SwiftUI

/// The real camera preview that sits behind the approved View Estate camera interface.
///
/// `resizeAspectFill` inside the approved 4:3 composition area keeps the sensor's own aspect
/// ratio, so the image is filled and cropped — never stretched.
struct CameraPreview: UIViewRepresentable {
    let service: CameraService

    func makeUIView(context: Context) -> CameraPreviewLayerView {
        let view = CameraPreviewLayerView()
        view.previewLayer.session = service.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        service.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewLayerView, context: Context) {
        if uiView.previewLayer.session !== service.session {
            uiView.previewLayer.session = service.session
            service.attach(previewLayer: uiView.previewLayer)
        }
    }
}

/// Hosting view whose backing layer IS the preview layer, so it always matches the bounds.
final class CameraPreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            return AVCaptureVideoPreviewLayer()
        }
        return layer
    }
}
