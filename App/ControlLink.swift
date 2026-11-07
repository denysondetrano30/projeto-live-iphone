import CryptoKit
import Foundation
import Network

/// Canal de controle com a fonte "Celular" do OBS, pelo Wi-Fi.
///
/// Usa TCP no mesmo número de porta do vídeo (o vídeo vai por SRT, que é UDP). Conversa em linhas:
///
/// - OBS → app: `PL1 <desafio>`
/// - app → OBS: `HELLO <HMAC-SHA256(senha do QR code, desafio) em hex> <nome da câmera>`
/// - OBS → app: `OK`, depois `TALLY on` (no ar) ou `TALLY off` sempre que mudar
/// - OBS → app: `CMD <número> <texto>` (aviso do diretor); app → OBS: `ACK <número>` no "Entendi"
/// - OBS → app: `AUDIO <porta UDP> <ficha>` e `VOICE <quem fala>` (intercom, veja `IntercomLink`)
/// - os dois lados: `PING` a cada 2 segundos; 6 segundos sem nada = caiu, e o app reconecta
///
/// Assim a senha nunca passa pela rede. Pelo cabo USB, as linhas `TALLY` chegam pelo próprio
/// túnel do cabo (veja `USBLink`).
final class ControlLink {
    /// Chamado (na fila do canal) quando a câmera entra (true) ou sai (false) do ar.
    var onTally: ((Bool) -> Void)?
    /// Chamado (na fila do canal) com cada aviso do diretor.
    var onCommand: ((UInt32, String) -> Void)?
    /// Intercom: caminho da voz pelo Wi-Fi (nil quando o canal cai).
    var onAudio: ((IntercomLink.WifiRoute?) -> Void)?
    /// Intercom: quem está falando ("-" = ninguém).
    var onVoice: ((String) -> Void)?

    private struct Target: Equatable {
        let host: String
        let port: UInt16
        let key: String
        let cameraName: String
    }

    private static let pingInterval: TimeInterval = 2
    private static let silenceLimit: TimeInterval = 6
    private static let retryDelay: TimeInterval = 2

    private let queue = DispatchQueue(label: "projetolive.control")
    private var target: Target?
    private var connection: NWConnection?
    private var attempt = 0
    private var reader = LineReader()
    private var authenticated = false
    private var tally = false
    private var lastReceived = Date.distantPast
    private var lastSent = Date.distantPast
    private var lastConnect = Date.distantPast
    private var timer: DispatchSourceTimer?

    /// Liga para o OBS (e continua tentando enquanto não for parado).
    func start(host: String, port: Int, key: String, cameraName: String) {
        guard let port = UInt16(exactly: port) else { return }
        let newTarget = Target(host: host, port: port, key: key, cameraName: cameraName)
        queue.async { [weak self] in
            guard let self, self.target != newTarget else { return }
            self.target = newTarget
            self.connect()
            self.startTimer()
        }
    }

    /// O operador tocou em "Entendi" no aviso `number`.
    func acknowledge(_ number: UInt32) {
        queue.async { [weak self] in
            guard let self, self.authenticated else { return }
            self.send("ACK \(number)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.target = nil
            self.timer?.cancel()
            self.timer = nil
            self.disconnect()
            self.setTally(false)
            self.onAudio?(nil)
            self.onVoice?("-")
        }
    }

    // MARK: - Conexão (tudo na fila do canal)

    private func connect() {
        disconnect()
        guard let target, let port = NWEndpoint.Port(rawValue: target.port) else { return }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let newConnection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: port,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        let thisAttempt = attempt
        connection = newConnection
        lastConnect = Date()
        lastReceived = Date()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.attempt == thisAttempt else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.receive(on: newConnection, attempt: thisAttempt)
            case .waiting, .failed:
                // O OBS não respondeu (fechado ou sem rede): tenta de novo pelo relógio.
                self.lost()
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    /// Fecha a conexão atual e ignora tudo o que ainda chegar dela.
    private func disconnect() {
        attempt += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reader = LineReader()
        authenticated = false
    }

    private func lost() {
        disconnect()
        setTally(false)
        onAudio?(nil)
        onVoice?("-")
    }

    private func receive(on connection: NWConnection, attempt thisAttempt: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.attempt == thisAttempt else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                for line in self.reader.feed(data) {
                    self.handle(line)
                    if self.attempt != thisAttempt { return }
                }
                if self.reader.overflowed {
                    self.lost()
                    return
                }
            }
            if isComplete || error != nil {
                self.lost()
                return
            }
            self.receive(on: connection, attempt: thisAttempt)
        }
    }

    private func handle(_ line: String) {
        guard let target else { return }
        if line.hasPrefix("PL1 ") {
            let challenge = String(line.dropFirst(4))
            let code = HMAC<SHA256>.authenticationCode(
                for: Data(challenge.utf8),
                using: SymmetricKey(data: Data(target.key.utf8))
            )
            let proof = code.map { String(format: "%02x", $0) }.joined()
            send("HELLO \(proof) \(target.cameraName)")
        } else if line == "OK" {
            authenticated = true
        } else if line == "TALLY on" {
            setTally(true)
        } else if line == "TALLY off" {
            setTally(false)
        } else if let command = DirectorInbox.parse(line) {
            onCommand?(command.number, command.text)
        } else if line.hasPrefix("AUDIO ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3, let port = UInt16(parts[1]), let token = Data(hex: String(parts[2])),
                token.count == 8
            {
                onAudio?(IntercomLink.WifiRoute(host: target.host, port: port, token: token))
            }
        } else if line.hasPrefix("VOICE ") {
            onVoice?(String(line.dropFirst(6)))
        } else if line.hasPrefix("ERR") {
            // Senha recusada (o OBS gerou um QR code novo). O vídeo também vai parar de conectar.
            lost()
        }
        // "PING" e linhas de versões futuras do OBS: nada a fazer.
    }

    private func send(_ text: String) {
        guard let connection else { return }
        lastSent = Date()
        connection.send(content: Data((text + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func setTally(_ value: Bool) {
        guard value != tally else { return }
        tally = value
        onTally?(value)
    }

    // MARK: - Relógio: PING, conexão que caiu e nova tentativa

    private func startTimer() {
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + 1, repeating: 1)
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        newTimer.resume()
        timer = newTimer
    }

    private func tick() {
        guard target != nil else { return }
        let now = Date()
        guard connection != nil else {
            if now.timeIntervalSince(lastConnect) >= Self.retryDelay {
                connect()
            }
            return
        }
        if now.timeIntervalSince(lastReceived) > Self.silenceLimit {
            lost()
            return
        }
        if authenticated && now.timeIntervalSince(lastSent) >= Self.pingInterval {
            send("PING")
        }
    }
}

/// Junta os pedaços que chegam da rede e devolve as linhas completas (terminadas em "\n").
struct LineReader {
    private static let maxLine = 4096
    private var buffer = Data()
    private(set) var overflowed = false

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maxLine {
            overflowed = true
            buffer.removeAll()
        }
        return lines
    }
}
