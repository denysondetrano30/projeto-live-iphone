import AVFoundation
import Foundation
import HaishinKit
import SRTHaishinKit
import VideoToolbox

/// Manda a imagem da câmera para o OBS do PC pelo Wi-Fi, usando o protocolo SRT.
///
/// Pareado (leu o QR code de uma fonte "Celular" no OBS): o iPhone liga para o PC, na porta e
/// com a senha daquela fonte, e reconecta sozinho se cair.
///
/// Sem pareamento (plano B): o iPhone fica esperando na porta 9000, e o OBS liga para ele
/// pelo endereço `srt://IP-DO-IPHONE:9000`.
final class PCLink: ObservableObject {
    enum State: Equatable {
        case starting
        case noWifi
        case waiting(address: String)
        case connecting(source: String)
        case sending(String)
        case failed(String)
    }

    static let port = 9000
    static let appVersion = "0.4"

    @Published private(set) var state: State = .starting
    @Published private(set) var pairing: Pairing?

    /// Nome fixo desta câmera, por exemplo "Câmera iPhone 4F2A". É sorteado na primeira vez.
    let cameraName: String = PCLink.makeCameraName()

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
    private var currentConnection: SRTConnection?
    private var pairingForLoop: Pairing?
    private var generation = 0
    private var loopTask: Task<Void, Never>?

    init() {
        let saved = PairingStore.load()
        pairing = saved
        pairingForLoop = saved
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop()
        }
    }

    /// Troca (ou apaga) o pareamento e reinicia a conexão na hora.
    func setPairing(_ newPairing: Pairing?) {
        PairingStore.save(newPairing)
        pairing = newPairing
        let connection: SRTConnection? = locked {
            pairingForLoop = newPairing
            generation += 1
            return currentConnection
        }
        if let connection {
            Task {
                await connection.close()
            }
        }
    }

    /// Recebe cada quadro da câmera (na fila de vídeo) e repassa ao OBS, se estiver conectado.
    func send(_ sampleBuffer: CMSampleBuffer) {
        guard let stream = locked({ activeStream }) else { return }
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
            let (pairing, startGeneration) = locked { (pairingForLoop, generation) }
            if let pairing {
                await runPaired(pairing, phoneIP: ip, generation: startGeneration)
            } else {
                await runUnpaired(phoneIP: ip)
            }
        }
    }

    /// Pareado: liga para o PC. Tenta cada endereço do QR code, primeiro o da mesma rede.
    private func runPaired(_ pairing: Pairing, phoneIP: String, generation startGeneration: Int) async {
        publish(.connecting(source: pairing.sourceName))
        for host in pairing.orderedHosts(phoneIP: phoneIP) {
            if pairingChanged(since: startGeneration) { return }
            let url = "srt://\(host):\(pairing.port)?mode=caller&passphrase=\(pairing.key)&pbkeylen=16"
            let status = "Enviando para \"\(pairing.sourceName)\" no OBS"
            let connected = await stream(to: url, status: status, generation: startGeneration)
            if connected {
                return
            }
        }
        // Nenhum endereço respondeu: o OBS pode estar fechado. Tenta de novo daqui a pouco.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Sem pareamento: espera o OBS ligar na porta 9000 (fica parado até alguém conectar).
    private func runUnpaired(phoneIP: String) async {
        let address = "\(phoneIP):\(Self.port)"
        publish(.waiting(address: address))
        let url = "srt://0.0.0.0:\(Self.port)?mode=listener"
        let connected = await stream(to: url, status: "Enviando para o PC · srt://\(address)", generation: nil)
        if !connected {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Conecta, manda a imagem enquanto a conexão durar e devolve true se chegou a conectar.
    private func stream(to url: String, status: String, generation startGeneration: Int?) async -> Bool {
        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        do {
            try await stream.setVideoSettings(Self.videoSettings)
        } catch {
            publish(.failed("Erro na configuração do vídeo. Avise o Claude."))
            return false
        }
        await stream.setExpectedMedias([.video])

        locked { currentConnection = connection }
        defer { locked { currentConnection = nil } }

        do {
            try await connection.connect(URL(string: url))
        } catch {
            return false
        }
        let isConnected = await connection.connected
        if !isConnected {
            await connection.close()
            return false
        }

        await stream.publish()
        locked { activeStream = stream }
        publish(.sending(status))

        while !Task.isCancelled {
            if let startGeneration, pairingChanged(since: startGeneration) { break }
            let stillConnected = await connection.connected
            if !stillConnected { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        locked { activeStream = nil }
        await connection.close()
        return true
    }

    // MARK: - Ajudantes

    private func pairingChanged(since startGeneration: Int) -> Bool {
        locked { generation != startGeneration }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }

    private static func makeCameraName() -> String {
        let key = "projetolive.cameraID"
        let defaults = UserDefaults.standard
        let id: String
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            id = saved
        } else {
            let raw = String(Int.random(in: 0...0xFFFF), radix: 16, uppercase: true)
            id = String(repeating: "0", count: max(0, 4 - raw.count)) + raw
            defaults.set(id, forKey: key)
        }
        return "Câmera iPhone \(id)"
    }
}
