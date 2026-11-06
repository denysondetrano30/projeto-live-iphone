import AVFoundation
import Combine
import UIKit

/// Cuida da câmera: pede permissão, liga a câmera traseira e aplica zoom, foco e exposição.
/// Também entrega cada quadro de vídeo para quem for mandar ao PC (o `PCLink`).
/// Toda mexida na câmera acontece numa fila própria, para a tela não travar.
final class CameraController: NSObject, ObservableObject {
    enum Status {
        case starting
        case running
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var maxZoom: CGFloat = 1.0
    @Published private(set) var isLocked = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "projetolive.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "projetolive.video")
    private let metadataOutput = AVCaptureMetadataOutput()
    /// Chamado com o texto de cada QR code lido (só na fila principal, e só no modo Parear).
    private var onCode: ((String) -> Void)?
    /// Lido e trocado só na `videoOutputQueue`.
    private var frameSink: ((CMSampleBuffer) -> Void)?
    private var device: AVCaptureDevice?
    private var maxZoomOnQueue: CGFloat = 1.0
    private var lockedOnQueue = false
    private var pinchStartZoom: CGFloat = 1.0

    /// Zoom máximo que oferecemos, mesmo que a câmera aceite mais (acima disso a imagem fica ruim).
    private let zoomLimit: CGFloat = 6.0

    // MARK: - Ligar a câmera

    /// Liga a câmera aos envios para o PC (Wi-Fi e cabo). Cada quadro passa também por `sink`.
    func attach(_ sink: @escaping (CMSampleBuffer) -> Void) {
        videoOutputQueue.async {
            self.frameSink = sink
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndRun()
                } else {
                    self.publishStatus(.denied)
                }
            }
        default:
            publishStatus(.denied)
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.device == nil {
                do {
                    try self.configureSession()
                } catch {
                    self.publishStatus(.failed(error.localizedDescription))
                    return
                }
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.publishStatus(.running)
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        // Em aparelhos com lente de zoom (como o 8 Plus), a câmera dupla troca sozinha
        // para essa lente a partir do 2x, e a imagem fica mais nítida.
        let dualCamera = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
        let wideCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let camera = dualCamera ?? wideCamera else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotUseCamera
        }
        session.addInput(input)
        device = camera

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotUseCamera
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }

        // Leitor de QR code para o pareamento. Fica desligado até tocar em Parear.
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = []
        }

        try camera.lockForConfiguration()
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        camera.unlockForConfiguration()

        let maxZoom = min(camera.activeFormat.videoMaxZoomFactor, zoomLimit)
        maxZoomOnQueue = maxZoom
        DispatchQueue.main.async {
            self.maxZoom = maxZoom
        }
    }

    private func publishStatus(_ newStatus: Status) {
        DispatchQueue.main.async {
            self.status = newStatus
        }
    }

    /// Gira os quadros enviados ao PC junto com o celular, para a imagem nunca chegar de cabeça para baixo.
    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let connection = self.videoOutput.connection(with: .video),
                  connection.isVideoOrientationSupported,
                  connection.videoOrientation != orientation else {
                return
            }
            connection.videoOrientation = orientation
        }
    }

    // MARK: - QR code

    func startScanning(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                self.metadataOutput.metadataObjectTypes = [.qr]
            }
        }
    }

    func stopScanning() {
        onCode = nil
        sessionQueue.async { [weak self] in
            self?.metadataOutput.metadataObjectTypes = []
        }
    }

    // MARK: - Zoom

    /// `smooth` faz o zoom andar devagar (bom para os botões); sem ele, o zoom segue o dedo.
    func setZoom(_ factor: CGFloat, smooth: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let target = max(1.0, min(factor, self.maxZoomOnQueue))
            do {
                try device.lockForConfiguration()
                if smooth {
                    device.ramp(toVideoZoomFactor: target, withRate: 6.0)
                } else {
                    device.videoZoomFactor = target
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.zoomFactor = target
                }
            } catch {
                // Se a câmera estiver ocupada, simplesmente ignoramos este ajuste.
            }
        }
    }

    /// Chamado pelo gesto de pinça na tela (sempre na fila principal).
    func pinch(scale: CGFloat, state: UIGestureRecognizer.State) {
        if state == .began {
            pinchStartZoom = zoomFactor
        }
        if state == .began || state == .changed {
            setZoom(pinchStartZoom * scale, smooth: false)
        }
    }

    // MARK: - Foco e exposição

    /// Toque na tela: foca e mede a luz naquele ponto, e solta a trava se estiver ligada.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
                self.lockedOnQueue = false
                DispatchQueue.main.async {
                    self.isLocked = false
                }
            } catch {
                // Ignorado: o próximo toque tenta de novo.
            }
        }
    }

    /// Trava (ou solta) foco, exposição e balanço de branco, para a imagem não ficar mudando no culto.
    func toggleLock() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let lock = !self.lockedOnQueue
            do {
                try device.lockForConfiguration()
                if lock {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.whiteBalanceMode = .locked
                    }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
                device.unlockForConfiguration()
                self.lockedOnQueue = lock
                DispatchQueue.main.async {
                    self.isLocked = lock
                }
            } catch {
                // Ignorado: o usuário pode tocar de novo.
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameSink?(sampleBuffer)
    }
}

extension CameraController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let onCode else { return }
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                onCode(text)
                return
            }
        }
    }
}

enum CameraError: LocalizedError {
    case noCamera
    case cannotUseCamera

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "Não encontrei a câmera traseira deste aparelho."
        case .cannotUseCamera:
            return "Não consegui usar a câmera. Feche outros apps que usam a câmera e abra de novo."
        }
    }
}
