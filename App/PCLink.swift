import AVFoundation
import Foundation

/// Manda a imagem da câmera para o OBS do PC pelo Wi-Fi, usando o protocolo SRT.
///
/// O vídeo é comprimido e empacotado pelo próprio app (`H264Encoder` + `TSMuxer`, os mesmos do cabo
/// USB), com o PTS no relógio do iPhone (`PhoneClock`), e vai pelo SRT (`SRTSender`).
///
/// Pareado (leu o QR code de uma fonte "Celular" no OBS): o iPhone liga para o PC, na porta e
/// com a senha daquela fonte, e reconecta sozinho se cair.
///
/// Sem pareamento (plano B): o iPhone fica esperando na porta 9000, e o OBS liga para ele
/// pelo endereço `srt://IP-DO-IPHONE:9000`.
///
/// Pareado, junto com o vídeo abre também o canal de controle (`ControlLink`), por onde o OBS
/// avisa se esta câmera está no ar.
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
    static let appVersion = "0.10"

    @Published private(set) var state: State = .starting
    @Published private(set) var pairing: Pairing?
    /// true enquanto o OBS estiver mostrando esta câmera no Programa (pelo Wi-Fi).
    @Published private(set) var onAir = false

    /// Nome fixo desta câmera, por exemplo "Câmera iPhone 4F2A". É sorteado na primeira vez.
    let cameraName: String = PCLink.makeCameraName()

    // Vídeo Full HD deitado, 30 quadros por segundo, 6 Mbps (veja `H264Encoder`).
    private let lock = NSLock()
    private let encoder = H264Encoder()
    private let muxer = TSMuxer()
    private let sender = SRTSender()
    private var sending = false
    private var pairingForLoop: Pairing?
    private var generation = 0
    private var loopTask: Task<Void, Never>?
    private let control = ControlLink()
    /// Onde os avisos do diretor que chegam pelo Wi-Fi são mostrados.
    weak var inbox: DirectorInbox?
    /// Intercom: recebe a porta da voz e quem está falando, que chegam pelo canal de controle.
    weak var intercom: IntercomLink?

    init() {
        let saved = PairingStore.load()
        pairing = saved
        pairingForLoop = saved
        control.onTally = { [weak self] value in
            DispatchQueue.main.async {
                self?.onAir = value
            }
        }
        control.onAudio = { [weak self] route in
            self?.intercom?.setWifiRoute(route)
        }
        control.onVoice = { [weak self] text in
            self?.intercom?.setVoice(text, cable: false)
        }
        control.onCommand = { [weak self] number, text in
            guard let self else { return }
            self.inbox?.receive(number: number, text: text) { [weak self] in
                self?.control.acknowledge(number)
            }
        }
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
        locked {
            pairingForLoop = newPairing
            generation += 1
        }
        sender.close()
    }

    /// Recebe cada quadro da câmera (na fila de vídeo) e repassa ao OBS, se estiver conectado.
    func send(_ sampleBuffer: CMSampleBuffer) {
        guard locked({ sending }) else { return }
        encoder.encode(sampleBuffer)
    }

    /// Quadro de som AAC (de `AACEncoder`), junto com a imagem.
    func sendAudio(_ adts: Data, pts: UInt64) {
        guard locked({ sending }) else { return }
        sender.send(muxer.muxAudio(adts: adts, pts: pts))
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
            let status = "Enviando para \"\(pairing.sourceName)\" no OBS"
            let control = (host: host, port: pairing.port, key: pairing.key)
            let connected = await stream(to: control, status: status, generation: startGeneration, control: control)
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
        let connected = await stream(
            to: nil,
            status: "Enviando para o PC · srt://\(address)",
            generation: nil,
            control: nil
        )
        if !connected {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Conecta, manda a imagem enquanto a conexão durar e devolve true se chegou a conectar.
    /// Com `control`, abre também o canal de controle no mesmo endereço (aviso de "no ar").
    /// `target` nil = plano B: espera o OBS ligar na porta 9000.
    private func stream(
        to target: (host: String, port: Int, key: String)?,
        status: String,
        generation startGeneration: Int?,
        control: (host: String, port: Int, key: String)?
    ) async -> Bool {
        let sender = self.sender
        let connected: Bool = await Task.detached(priority: .userInitiated) {
            if let target {
                return sender.connect(host: target.host, port: target.port, passphrase: target.key)
            }
            return sender.listen(port: Self.port)
        }.value
        guard connected else {
            sender.close()
            return false
        }

        muxer.reset()
        encoder.start { [weak self] accessUnit, pts, isKeyFrame in
            guard let self else { return }
            let packets = self.muxer.mux(accessUnit: accessUnit, pts: pts, isKeyFrame: isKeyFrame)
            self.sender.send(packets)
        }
        locked { sending = true }
        publish(.sending(status))
        if let control {
            self.control.start(host: control.host, port: control.port, key: control.key, cameraName: cameraName)
        }

        while !Task.isCancelled {
            if let startGeneration, pairingChanged(since: startGeneration) { break }
            if !sender.isConnected { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        locked { sending = false }
        encoder.stop()
        self.control.stop()
        sender.close()
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
