import AVFoundation
import Foundation
import HaishinKit
import SRTHaishinKit
import VideoToolbox

/// Manda a imagem da câmera para o OBS do PC pelo Wi-Fi, usando o protocolo SRT.
///
/// O iPhone fica "escutando" na porta 9000. No OBS, uma Fonte de mídia com o endereço
/// `srt://IP-DO-IPHONE:9000` conecta nele e começa a receber a imagem.
/// Quando o OBS desconecta, o iPhone volta a esperar sozinho.
final class PCLink: ObservableObject {
    enum State: Equatable {
        case starting
        case noWifi
        case waiting(address: String)
        case sending(address: String)
        case failed(String)
    }

    static let port = 9000

    @Published private(set) var state: State = .starting

    /// Vídeo Full HD deitado, 30 quadros por segundo, 6 Mbps (folgado para a rede local).
    private static let videoSettings = VideoCodecSettings(
        videoSize: CGSize(width: 1920, height: 1080),
        bitRate: 6_000_000,
        profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
        maxKeyFrameIntervalDuration: 1,
        allowFrameReordering: false,
        expectedFrameRate: 30
    )

    private let lock = NSLock()
    private var activeStream: SRTStream?
    private var loopTask: Task<Void, Never>?

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop()
        }
    }

    /// Recebe cada quadro da câmera (na fila de vídeo) e repassa ao OBS, se estiver conectado.
    func send(_ sampleBuffer: CMSampleBuffer) {
        guard let stream = currentStream() else { return }
        Task {
            await stream.append(sampleBuffer)
        }
    }

    // MARK: - Ciclo de conexão

    private func runLoop() async {
        while !Task.isCancelled {
            guard let ip = NetworkInfo.wifiIPv4() else {
                publish(.noWifi)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let address = "\(ip):\(Self.port)"
            publish(.waiting(address: address))

            let connection = SRTConnection()
            let stream = SRTStream(connection: connection)
            do {
                try await stream.setVideoSettings(Self.videoSettings)
            } catch {
                publish(.failed("Erro na configuração do vídeo. Avise o Claude."))
                return
            }
            await stream.setExpectedMedias([.video])

            // Fica parado aqui até o OBS conectar.
            do {
                try await connection.connect(URL(string: "srt://0.0.0.0:\(Self.port)?mode=listener"))
            } catch {
                publish(.failed("Não consegui abrir a porta \(Self.port). Tentando de novo…"))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            await stream.publish()
            setActiveStream(stream)
            publish(.sending(address: address))

            // Enquanto o OBS estiver conectado, os quadros seguem para ele.
            while !Task.isCancelled {
                let stillConnected = await connection.connected
                if !stillConnected {
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            setActiveStream(nil)
            await connection.close()
        }
    }

    // MARK: - Ajudantes

    private func currentStream() -> SRTStream? {
        lock.lock()
        defer { lock.unlock() }
        return activeStream
    }

    private func setActiveStream(_ stream: SRTStream?) {
        lock.lock()
        activeStream = stream
        lock.unlock()
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }
}
