import Combine
import CoreMedia
import Foundation
import Network
import VideoToolbox

/// Manda a imagem pelo cabo USB.
///
/// No Windows, o cabo do iPhone passa pelo serviço "Apple Mobile Device" (vem com o iTunes),
/// que só leva conexões TCP do PC para o iPhone. Então o app escuta na porta 9010; quando a fonte
/// "Celular" do OBS (modo Cabo USB) conecta, o app comprime o vídeo em H.264 e manda em MPEG-TS,
/// o mesmo formato que vai pelo Wi-Fi.
///
/// No sentido contrário, pela mesma conexão, o OBS avisa se esta câmera está no ar
/// (linhas `TALLY on` e `TALLY off`).
///
/// Além disso o app escuta na porta 9011 (controle): por ela chegam o "no ar" e os avisos do
/// diretor (`CMD <número> <texto>`), e o app responde `ACK <número>` quando o operador toca em
/// "Entendi". Ao conectar, o app se apresenta com `HELLO usb <nome da câmera>`.
final class USBLink: ObservableObject {
    static let port: UInt16 = 9010
    static let controlPort: UInt16 = 9011

    /// true enquanto o PC estiver recebendo a imagem pelo cabo.
    @Published private(set) var isConnected = false
    /// true enquanto o OBS estiver mostrando esta câmera no Programa (pelo cabo).
    @Published private(set) var onAir = false

    private let queue = DispatchQueue(label: "projetolive.usb")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let encoder = H264Encoder()
    private let muxer = TSMuxer()
    private var pendingBytes = 0
    private var commands = LineReader()
    private var controlListener: NWListener?
    private var controlConnection: NWConnection?
    private var controlLines = LineReader()
    private var cameraName = "iPhone"
    private let lock = NSLock()
    /// Onde os avisos do diretor que chegam pelo cabo são mostrados.
    weak var inbox: DirectorInbox?
    /// Intercom: recebe quem está falando (a voz pelo cabo usa a porta 9012, em `IntercomLink`).
    weak var intercom: IntercomLink?
    private var sending = false

    func start(cameraName: String) {
        queue.async { [weak self] in
            self?.cameraName = cameraName
            self?.startListener()
            self?.startControlListener()
        }
    }

    /// Recebe cada quadro da câmera (na fila de vídeo). Só comprime se o PC estiver ligado no cabo.
    func send(_ sampleBuffer: CMSampleBuffer) {
        guard isSending() else { return }
        encoder.encode(sampleBuffer)
    }

    // MARK: - Conexão

    private func startListener() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.restartLater()
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            restartLater()
        }
    }

    private func startControlListener() {
        guard controlListener == nil, let port = NWEndpoint.Port(rawValue: Self.controlPort) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptControl(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.restartControlLater()
                }
            }
            listener.start(queue: queue)
            controlListener = listener
        } catch {
            restartControlLater()
        }
    }

    private func restartControlLater() {
        controlListener?.cancel()
        controlListener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startControlListener()
        }
    }

    private func acceptControl(_ newConnection: NWConnection) {
        controlConnection?.cancel()
        controlConnection = newConnection
        controlLines = LineReader()
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.controlConnection === newConnection else { return }
            switch state {
            case .ready:
                self.sendControl("HELLO usb \(self.cameraName)")
                self.receiveControl(on: newConnection)
            case .failed, .cancelled:
                self.controlConnection = nil
                self.intercom?.setVoice("-", cable: true)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveControl(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.controlConnection === connection else { return }
            if let data, !data.isEmpty {
                for line in self.controlLines.feed(data) {
                    self.handleControl(line)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveControl(on: connection)
        }
    }

    private func handleControl(_ line: String) {
        if line == "TALLY on" {
            notifyTally(true)
        } else if line == "TALLY off" {
            notifyTally(false)
        } else if let reply = PhoneClock.timeReply(line) {
            sendControl(reply)
        } else if line.hasPrefix("VOICE ") {
            intercom?.setVoice(String(line.dropFirst(6)), cable: true)
        } else if let command = DirectorInbox.parse(line) {
            let number = command.number
            inbox?.receive(number: number, text: command.text) { [weak self] in
                self?.queue.async {
                    self?.sendControl("ACK \(number)")
                }
            }
        }
        // "PING": nada a fazer.
    }

    private func sendControl(_ text: String) {
        controlConnection?.send(content: Data((text + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func restartLater() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startListener()
        }
    }

    private func accept(_ newConnection: NWConnection) {
        // Um PC por vez: a conexão nova substitui a antiga.
        connection?.cancel()
        connection = newConnection
        pendingBytes = 0
        commands = LineReader()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                self.muxer.reset()
                self.encoder.start { [weak self] accessUnit, pts, isKeyFrame in
                    self?.deliver(accessUnit, pts: pts, isKeyFrame: isKeyFrame)
                }
                self.setSending(true)
                self.notify(true)
                self.receiveCommands(on: newConnection)
            case .failed, .cancelled:
                if self.connection === newConnection {
                    self.stopSending()
                }
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func stopSending() {
        setSending(false)
        encoder.stop()
        connection = nil
        notify(false)
        notifyTally(false)
    }

    /// Lê os avisos que o OBS manda pelo cabo (uma linha de texto por aviso).
    private func receiveCommands(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                for line in self.commands.feed(data) {
                    if line == "TALLY on" {
                        self.notifyTally(true)
                    } else if line == "TALLY off" {
                        self.notifyTally(false)
                    }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveCommands(on: connection)
        }
    }

    /// Chamado pelo codificador (fila dele) com cada quadro comprimido.
    private func deliver(_ accessUnit: Data, pts: UInt64, isKeyFrame: Bool) {
        let packets = muxer.mux(accessUnit: accessUnit, pts: pts, isKeyFrame: isKeyFrame)
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            // Se o cabo estiver atrasado (mais de 4 MB na fila), descarta até o próximo quadro-chave.
            if self.pendingBytes > 4_000_000 && !isKeyFrame {
                return
            }
            self.pendingBytes += packets.count
            connection.send(content: packets, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.pendingBytes -= packets.count
                    if error != nil {
                        connection.cancel()
                    }
                }
            })
        }
    }

    // MARK: - Ajudantes

    private func isSending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sending
    }

    private func setSending(_ value: Bool) {
        lock.lock()
        sending = value
        lock.unlock()
    }

    private func notify(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
        }
    }

    private func notifyTally(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            if self?.onAir != value {
                self?.onAir = value
            }
        }
    }
}

// MARK: - Codificador H.264

/// Comprime os quadros da câmera em H.264 (no chip do iPhone) e entrega cada quadro
/// em formato Annex B, já com SPS/PPS antes dos quadros-chave.
final class H264Encoder {
    typealias Output = (_ accessUnit: Data, _ pts: UInt64, _ isKeyFrame: Bool) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var output: Output?
    private var forceKeyFrame = true

    func start(output: @escaping Output) {
        lock.lock()
        self.output = output
        forceKeyFrame = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let oldSession = session
        session = nil
        output = nil
        lock.unlock()
        if let oldSession {
            VTCompressionSessionInvalidate(oldSession)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        if session == nil {
            session = makeSession(
                width: Int32(CVPixelBufferGetWidth(imageBuffer)),
                height: Int32(CVPixelBufferGetHeight(imageBuffer))
            )
        }
        let session = self.session
        let force = forceKeyFrame
        forceKeyFrame = false
        lock.unlock()

        guard let session else { return }

        // PTS = relógio do iPhone na hora em que o quadro foi filmado (veja `PhoneClock`).
        let pts = PhoneClock.pts90k(time)

        var properties: CFDictionary?
        if force {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        _ = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.handle(encoded, pts: pts)
        }
    }

    private func makeSession(width: Int32, height: Int32) -> VTCompressionSession? {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { return nil }

        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 6_000_000)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 30)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1)),
            // Cada quadro sai do codificador assim que fica pronto (sem esperar os próximos).
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        ]
        for (key, value) in settings {
            _ = VTSessionSetProperty(newSession, key: key, value: value)
        }
        _ = VTCompressionSessionPrepareToEncodeFrames(newSession)
        return newSession
    }

    private func handle(_ encoded: CMSampleBuffer, pts: UInt64) {
        lock.lock()
        let output = self.output
        lock.unlock()
        guard let output,
              let dataBuffer = CMSampleBufferGetDataBuffer(encoded),
              let format = CMSampleBufferGetFormatDescription(encoded) else {
            return
        }

        let isKeyFrame = Self.isKeyFrame(encoded)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var accessUnit = Data()
        // Delimitador de quadro (AUD), exigido no H.264 dentro de MPEG-TS.
        accessUnit.append(contentsOf: startCode + [0x09, 0xF0])

        if isKeyFrame {
            for parameterSet in Self.parameterSets(format) {
                accessUnit.append(contentsOf: startCode)
                accessUnit.append(parameterSet)
            }
        }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else {
            return
        }

        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &headerLength
        )

        let bytes = UnsafeRawPointer(pointer)
        var offset = 0
        let lengthSize = Int(headerLength)
        while offset + lengthSize <= totalLength {
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = (nalLength << 8) | Int(bytes.load(fromByteOffset: offset + index, as: UInt8.self))
            }
            offset += lengthSize
            guard nalLength > 0, offset + nalLength <= totalLength else { break }
            accessUnit.append(contentsOf: startCode)
            accessUnit.append(Data(bytes: bytes.advanced(by: offset), count: nalLength))
            offset += nalLength
        }

        output(accessUnit, pts, isKeyFrame)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}

// MARK: - MPEG-TS

/// Empacota quadros H.264 em MPEG-TS (pacotes de 188 bytes), o formato que o OBS lê como "mpegts".
final class TSMuxer {
    private static let packetSize = 188
    private static let patPID: UInt16 = 0x0000
    private static let pmtPID: UInt16 = 0x1000
    private static let videoPID: UInt16 = 0x0100

    private var continuity: [UInt16: UInt8] = [:]

    func reset() {
        continuity = [:]
    }

    func mux(accessUnit: Data, pts: UInt64, isKeyFrame: Bool) -> Data {
        var out = Data()
        if isKeyFrame {
            out.append(psiPacket(pid: Self.patPID, section: Self.patSection()))
            out.append(psiPacket(pid: Self.pmtPID, section: Self.pmtSection()))
        }

        var pes = Data([0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x84, 0x80, 0x05])
        pes.append(contentsOf: Self.timestamp(pts))
        pes.append(accessUnit)

        // O relógio de referência (PCR) vai um pouco antes do quadro.
        let pcr = pts > 3_000 ? pts - 3_000 : 0
        out.append(packetize(pid: Self.videoPID, payload: pes, pcr: pcr, randomAccess: isKeyFrame))
        return out
    }

    private func nextContinuity(_ pid: UInt16) -> UInt8 {
        let value = continuity[pid] ?? 0
        continuity[pid] = (value + 1) & 0x0F
        return value
    }

    private func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var packet = [UInt8](repeating: 0xFF, count: Self.packetSize)
        packet[0] = 0x47
        packet[1] = 0x40 | UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10 | nextContinuity(pid)
        packet[4] = 0x00 // pointer_field
        for (index, byte) in section.enumerated() {
            packet[5 + index] = byte
        }
        return Data(packet)
    }

    private func packetize(pid: UInt16, payload: Data, pcr: UInt64, randomAccess: Bool) -> Data {
        var out = Data()
        let bytes = [UInt8](payload)
        var offset = 0
        var first = true

        while offset < bytes.count {
            var adaptation: [UInt8] = []
            var hasAdaptation = false
            if first {
                hasAdaptation = true
                adaptation.append(0x10 | (randomAccess ? 0x40 : 0x00)) // PCR (+ acesso aleatório)
                adaptation.append(contentsOf: Self.pcrBytes(pcr))
            }

            let headerSpace = hasAdaptation ? 1 + adaptation.count : 0
            var space = 184 - headerSpace
            let remaining = bytes.count - offset
            if remaining < space {
                let stuffing = space - remaining
                if hasAdaptation {
                    adaptation.append(contentsOf: [UInt8](repeating: 0xFF, count: stuffing))
                } else {
                    hasAdaptation = true
                    if stuffing >= 2 {
                        adaptation.append(0x00)
                        adaptation.append(contentsOf: [UInt8](repeating: 0xFF, count: stuffing - 2))
                    }
                }
                space = remaining
            }

            var packet: [UInt8] = [
                0x47,
                (first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F),
                UInt8(pid & 0xFF),
                (hasAdaptation ? 0x30 : 0x10) | nextContinuity(pid)
            ]
            if hasAdaptation {
                packet.append(UInt8(adaptation.count))
                packet.append(contentsOf: adaptation)
            }
            packet.append(contentsOf: bytes[offset..<(offset + space)])
            out.append(contentsOf: packet)

            offset += space
            first = false
        }
        return out
    }

    private static func timestamp(_ pts: UInt64) -> [UInt8] {
        let value = pts & 0x1_FFFF_FFFF
        return [
            UInt8(0x21 | ((value >> 29) & 0x0E)),
            UInt8((value >> 22) & 0xFF),
            UInt8(((value >> 14) & 0xFE) | 0x01),
            UInt8((value >> 7) & 0xFF),
            UInt8(((value << 1) & 0xFE) | 0x01)
        ]
    }

    private static func pcrBytes(_ pcr: UInt64) -> [UInt8] {
        let base = pcr & 0x1_FFFF_FFFF
        return [
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8(((base & 0x01) << 7) | 0x7E),
            0x00
        ]
    }

    private static func patSection() -> [UInt8] {
        var section: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00]
        section.append(contentsOf: crc32(section))
        return section
    }

    private static func pmtSection() -> [UInt8] {
        var section: [UInt8] = [
            0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x00, // PCR no PID do vídeo (0x100)
            0xF0, 0x00, // sem descritores do programa
            0x1B, 0xE1, 0x00, 0xF0, 0x00 // H.264 no PID 0x100
        ]
        section.append(contentsOf: crc32(section))
        return section
    }

    /// CRC-32 do MPEG-2 (polinômio 0x04C11DB7, sem inversão).
    private static func crc32(_ data: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}
