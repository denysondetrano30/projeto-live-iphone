import AVFoundation
import Foundation
import Network

/// Intercom: conversa por voz com o diretor e com as outras câmeras ("Segure para falar").
///
/// O PC é a central e mistura as vozes; ele manda para cada celular só o que esse celular deve
/// ouvir. Voz em 16 kHz, mono, 16 bits, em quadros de 20 ms (320 amostras), sem compressão.
///
/// Pacote: `PLV1` | ficha (8 bytes) | sequência (2 bytes, little-endian) | marcas (1 byte) | 0 |
/// voz (640 bytes, só quando a marca 1 está ligada).
///
/// - Wi-Fi: UDP para a porta que o OBS mandou pelo canal de controle (`AUDIO <porta> <ficha>`).
///   Um pacote sem voz a cada segundo avisa o PC do endereço do celular.
/// - Cabo: o OBS conecta na porta 9012 do app; cada pacote vai precedido do tamanho (2 bytes).
///
/// O som só toca com fone de ouvido, para a voz do intercom não vazar no ambiente.
///
/// O mesmo microfone também vai para a câmera (`cameraAudio`): o som que acompanha a imagem no OBS.
/// Um microfone ligado no USB-C/Lightning (como um receptor sem fio) é preferido. Enquanto a pessoa
/// fala no intercom, a câmera manda silêncio, para a conversa não entrar na live.
final class IntercomLink: ObservableObject {
    /// Som do microfone para a câmera: pedaço, hora (relógio do iPhone) e se deve ir em silêncio.
    /// Chamado na thread de som.
    var cameraAudio: ((AVAudioPCMBuffer, AVAudioTime, Bool) -> Void)?
    private let talkingLock = NSLock()
    private var talkingNow = false

    struct WifiRoute: Equatable {
        let host: String
        let port: UInt16
        let token: Data
    }

    static let cablePort: UInt16 = 9012
    private static let frameSamples = 320
    private static let headerSize = 16
    private static let packetSize = headerSize + frameSamples * 2
    private static let flagAudio: UInt8 = 1
    private static let magic = Data("PLV1".utf8)
    /// Mais de 200 ms esperando para tocar: o som atrasou, e o que chega é descartado.
    private static let maxQueuedFrames = 10

    /// Há um caminho até o PC (Wi-Fi pareado ou cabo).
    @Published private(set) var isAvailable = false
    @Published private(set) var hasHeadset = false
    @Published private(set) var isTalking = false
    /// Quem está falando agora (como "Diretor" ou "CAM 2"), ou nil.
    @Published private(set) var speaking: String?
    @Published private(set) var micDenied = false

    private let queue = DispatchQueue(label: "projetolive.intercom")

    // Rede (tudo na fila `queue`)
    private var route: WifiRoute?
    private var udp: NWConnection?
    private var cableListener: NWListener?
    private var cable: NWConnection?
    private var cableBuffer = Data()
    private var sequence: UInt16 = 0
    private var keepAlive: DispatchSourceTimer?
    private var voiceWifi = "-"
    private var voiceCable = "-"
    private var available = false

    // Som (tudo na fila `queue`)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var engineRunning = false
    private var playerAttached = false
    private var tapInstalled = false
    private var pending: [Int16] = []
    private var queuedFrames = 0
    private var talking = false
    private var headset = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startCableListener()
            self.startKeepAlive()
            self.observeAudio()
            self.updateHeadset()
        }
    }

    // MARK: - Chamado pelo canal de controle e pela tela

    /// Wi-Fi: o OBS mandou "AUDIO <porta> <ficha>" (nil = o canal de controle caiu).
    func setWifiRoute(_ newRoute: WifiRoute?) {
        queue.async { [weak self] in
            guard let self, self.route != newRoute else { return }
            self.udp?.cancel()
            self.udp = nil
            self.route = newRoute
            if let newRoute, let port = NWEndpoint.Port(rawValue: newRoute.port) {
                let connection = NWConnection(host: NWEndpoint.Host(newRoute.host), port: port, using: .udp)
                connection.start(queue: self.queue)
                self.udp = connection
                self.receiveUDP(on: connection)
                self.sendPacket(voice: nil)
            } else {
                self.voiceWifi = "-"
            }
            self.updateAvailability()
        }
    }

    /// Linha "VOICE <quem fala>" que chegou pelo Wi-Fi (cable = false) ou pelo cabo.
    func setVoice(_ text: String, cable fromCable: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if fromCable {
                self.voiceCable = text
            } else {
                self.voiceWifi = text
            }
            self.publishSpeaking()
        }
    }

    /// "Segure para falar": true ao apertar, false ao soltar.
    func setTalking(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if value && !self.tapInstalled {
                self.askMicrophone()
            }
            self.talking = value
            self.talkingLock.lock()
            self.talkingNow = value
            self.talkingLock.unlock()
            if !value {
                self.pending.removeAll()
            }
            DispatchQueue.main.async {
                self.isTalking = value
            }
        }
    }

    // MARK: - Disponibilidade

    private func updateAvailability() {
        let now = cable != nil || route != nil
        guard now != available else {
            publishSpeaking()
            return
        }
        available = now
        if now {
            startAudio()
        } else {
            stopAudio()
            talking = false
            pending.removeAll()
        }
        publishSpeaking()
        DispatchQueue.main.async { [weak self] in
            self?.isAvailable = now
            if !now {
                self?.isTalking = false
            }
        }
    }

    private func publishSpeaking() {
        let text = cable != nil ? voiceCable : voiceWifi
        let value: String? = (available && text != "-" && !text.isEmpty) ? text : nil
        DispatchQueue.main.async { [weak self] in
            if self?.speaking != value {
                self?.speaking = value
            }
        }
    }

    // MARK: - Som

    private func startAudio() {
        guard !engineRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            // Sem isto, o iPhone corta a vibração dos avisos do diretor enquanto o microfone estiver aberto.
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            return
        }

        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            playerAttached = true
        }
        preferExternalMicrophone()
        if session.recordPermission == .granted {
            installTap()
        } else if session.recordPermission == .denied {
            publishMicDenied(true)
        } else {
            // O som da câmera precisa do microfone desde o começo (não só no "Segure para falar").
            askMicrophone()
        }
        runEngine()
        updateHeadset()
    }

    private func runEngine() {
        do {
            engine.prepare()
            try engine.start()
            player.play()
            engineRunning = true
        } catch {
            engineRunning = false
        }
    }

    private func stopAudio() {
        guard engineRunning else { return }
        player.stop()
        engine.stop()
        engineRunning = false
        queuedFrames = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func askMicrophone() {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            restartWithMicrophone()
        case .denied:
            publishMicDenied(true)
        default:
            session.requestRecordPermission { [weak self] granted in
                self?.queue.async {
                    if granted {
                        self?.restartWithMicrophone()
                    } else {
                        self?.publishMicDenied(true)
                    }
                }
            }
        }
    }

    private func restartWithMicrophone() {
        publishMicDenied(false)
        guard available, !tapInstalled else { return }
        if engineRunning {
            player.stop()
            engine.stop()
            engineRunning = false
            queuedFrames = 0
        }
        installTap()
        runEngine()
    }

    /// Microfone ligado no USB-C/Lightning (receptor sem fio, interface de áudio) tem preferência.
    private func preferExternalMicrophone() {
        let session = AVAudioSession.sharedInstance()
        guard let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio || $0.portType == .headsetMic })
        else { return }
        if session.preferredInput?.uid != usb.uid {
            try? session.setPreferredInput(usb)
        }
    }

    private func installTap() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
            let converter = AVAudioConverter(from: format, to: sendFormat)
        else { return }
        let sendFormat = self.sendFormat
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            // Thread de som: só converte para 16 kHz e passa para a fila do intercom.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            _ = converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0, let channel = converted.int16ChannelData {
                let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
                self?.queue.async {
                    self?.captured(samples)
                }
            }
            // Depois do intercom: o som da câmera (silêncio enquanto alguém fala no intercom).
            if let self, let cameraAudio = self.cameraAudio {
                self.talkingLock.lock()
                let silent = self.talkingNow
                self.talkingLock.unlock()
                cameraAudio(buffer, when, silent)
            }
        }
        tapInstalled = true
    }

    private func captured(_ samples: [Int16]) {
        guard talking, available else {
            pending.removeAll()
            return
        }
        pending.append(contentsOf: samples)
        while pending.count >= Self.frameSamples {
            let frame = Array(pending.prefix(Self.frameSamples))
            pending.removeFirst(Self.frameSamples)
            sendPacket(voice: frame)
        }
    }

    private func play(_ packet: Data) {
        guard headset, engineRunning, queuedFrames < Self.maxQueuedFrames else { return }
        if queuedFrames == 0 {
            // Começo de uma fala: 40 ms de silêncio na frente seguram as variações da rede.
            schedule(nil)
            schedule(nil)
        }
        schedule(packet)
    }

    private func schedule(_ packet: Data?) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(Self.frameSamples)),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(Self.frameSamples)
        if let packet {
            packet.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let base = bytes.startIndex + Self.headerSize
                for i in 0..<Self.frameSamples {
                    let value = UInt16(bytes[base + i * 2]) | (UInt16(bytes[base + i * 2 + 1]) << 8)
                    channel[i] = Float(Int16(bitPattern: value)) / 32768
                }
            }
        } else {
            for i in 0..<Self.frameSamples {
                channel[i] = 0
            }
        }
        queuedFrames += 1
        player.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                if let self, self.queuedFrames > 0 {
                    self.queuedFrames -= 1
                }
            }
        }
    }

    private func observeAudio() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) {
                [weak self] _ in
                self?.queue.async {
                    self?.preferExternalMicrophone()
                    self?.updateHeadset()
                }
            })
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
                [weak self] _ in
                self?.queue.async { self?.engineChanged() }
            })
    }

    /// O iPhone trocou o aparelho de som (fone ligado ou desligado): refaz a ligação com o microfone.
    private func engineChanged() {
        guard available else { return }
        engineRunning = false
        queuedFrames = 0
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            installTap()
        }
        runEngine()
    }

    private func updateHeadset() {
        let ports: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let value = outputs.contains { ports.contains($0.portType) }
        headset = value
        DispatchQueue.main.async { [weak self] in
            if self?.hasHeadset != value {
                self?.hasHeadset = value
            }
        }
    }

    private func publishMicDenied(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            if self?.micDenied != value {
                self?.micDenied = value
            }
        }
    }

    // MARK: - Pacotes

    private func sendPacket(voice: [Int16]?) {
        var packet = Data(capacity: Self.packetSize)
        packet.append(Self.magic)
        packet.append(route?.token ?? Data(count: 8))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(UInt8(sequence >> 8))
        sequence &+= 1
        packet.append(voice == nil ? 0 : Self.flagAudio)
        packet.append(0)
        if let voice {
            for sample in voice {
                let value = UInt16(bitPattern: sample)
                packet.append(UInt8(value & 0xFF))
                packet.append(UInt8(value >> 8))
            }
        }

        if let cable {
            var framed = Data([UInt8(packet.count & 0xFF), UInt8(packet.count >> 8)])
            framed.append(packet)
            cable.send(content: framed, completion: .contentProcessed { _ in })
        } else if let udp {
            udp.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func handleIncoming(_ packet: Data, checkToken: Bool) {
        guard packet.count >= Self.packetSize, packet.prefix(4) == Self.magic else { return }
        let start = packet.startIndex
        if checkToken {
            guard let token = route?.token, packet[(start + 4)..<(start + 12)] == token else { return }
        }
        guard packet[start + 14] & Self.flagAudio != 0 else { return }
        play(Data(packet))
    }

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.udp === connection else { return }
            if let data {
                self.handleIncoming(data, checkToken: true)
            }
            if error == nil {
                self.receiveUDP(on: connection)
            }
        }
    }

    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.udp != nil, self.cable == nil else { return }
            self.sendPacket(voice: nil)
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: - Cabo (porta 9012)

    private func startCableListener() {
        guard cableListener == nil, let port = NWEndpoint.Port(rawValue: Self.cablePort) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptCable(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.restartCableListenerLater()
                }
            }
            listener.start(queue: queue)
            cableListener = listener
        } catch {
            restartCableListenerLater()
        }
    }

    private func restartCableListenerLater() {
        cableListener?.cancel()
        cableListener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startCableListener()
        }
    }

    private func acceptCable(_ newConnection: NWConnection) {
        cable?.cancel()
        cable = newConnection
        cableBuffer.removeAll()
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.cable === newConnection else { return }
            switch state {
            case .ready:
                self.receiveCable(on: newConnection)
                self.updateAvailability()
            case .failed, .cancelled:
                self.cable = nil
                self.voiceCable = "-"
                self.updateAvailability()
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveCable(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, self.cable === connection else { return }
            if let data, !data.isEmpty {
                self.cableBuffer.append(data)
                while self.cableBuffer.count >= 2 {
                    let start = self.cableBuffer.startIndex
                    let length = Int(self.cableBuffer[start]) | (Int(self.cableBuffer[start + 1]) << 8)
                    guard length >= Self.headerSize, length <= Self.packetSize else {
                        connection.cancel()
                        return
                    }
                    guard self.cableBuffer.count >= 2 + length else { break }
                    let packet = self.cableBuffer.subdata(in: (start + 2)..<(start + 2 + length))
                    self.cableBuffer.removeSubrange(start..<(start + 2 + length))
                    self.handleIncoming(packet, checkToken: false)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveCable(on: connection)
        }
    }
}

extension Data {
    /// "a1b2..." → bytes. nil se o texto não for hexadecimal com número par de dígitos.
    init?(hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < characters.count {
            guard let high = value(characters[i]), let low = value(characters[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
            i += 2
        }
        self.init(bytes)
    }
}
