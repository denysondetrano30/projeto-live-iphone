import AVFoundation
import SwiftUI
import UIKit

/// Mostra a imagem da câmera na tela e repassa toques e pinças.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (CGPoint) -> Void
    var onPinch: (CGFloat, UIGestureRecognizer.State) -> Void
    var onOrientation: (AVCaptureVideoOrientation) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.onTap = onTap
        view.onPinch = onPinch
        view.onOrientation = onOrientation
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
        uiView.onPinch = onPinch
        uiView.onOrientation = onOrientation
        uiView.updateOrientation()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    var onOrientation: ((AVCaptureVideoOrientation) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Mostra o quadro inteiro, exatamente o que vai para a transmissão.
        previewLayer.videoGravity = .resizeAspect
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) não é usado")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateOrientation()
    }

    /// Gira a imagem junto com a tela e avisa a câmera, para o vídeo enviado girar junto.
    func updateOrientation() {
        guard let interfaceOrientation = window?.windowScene?.interfaceOrientation else {
            return
        }
        let videoOrientation: AVCaptureVideoOrientation
        switch interfaceOrientation {
        case .landscapeLeft:
            videoOrientation = .landscapeLeft
        case .landscapeRight:
            videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        default:
            videoOrientation = .portrait
        }
        if let connection = previewLayer.connection,
           connection.isVideoOrientationSupported,
           connection.videoOrientation != videoOrientation {
            connection.videoOrientation = videoOrientation
        }
        onOrientation?(videoOrientation)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let layerPoint = gesture.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        onPinch?(gesture.scale, gesture.state)
    }
}
