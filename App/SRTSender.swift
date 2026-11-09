import Darwin
import Foundation
import libsrt

/// Envio SRT direto pela libsrt (sem a pilha de transmissão do HaishinKit).
///
/// O app comprime e empacota o vídeo ele mesmo (`H264Encoder` + `TSMuxer`, os mesmos do cabo USB),
/// com o PTS no relógio do iPhone (`PhoneClock`), e esta classe só entrega os pacotes MPEG-TS ao
/// OBS em mensagens SRT de 1316 bytes (7 pacotes de 188).
///
/// - Pareado: liga para o OBS (`caller`), com a senha do QR code.
/// - Plano B: espera o OBS ligar (`listener`) na porta 9000, sem senha.
final class SRTSender {
    private static let messageSize = 1316
    /// Folga para reenviar pacotes perdidos: 60 ms basta numa rede local (o padrão do SRT é 120).
    private static let latencyMs: Int32 = 60
    private static let startup: Void = {
        _ = srt_startup()
    }()

    private let lock = NSLock()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var listenSocket: SRTSOCKET = SRT_INVALID_SOCK
    private var pending = Data()

    init() {
        _ = Self.startup
    }

    /// Liga para o OBS. Bloqueia até conectar ou desistir (uns 3 segundos).
    func connect(host: String, port: Int, passphrase: String?) -> Bool {
        close()
        let newSocket = srt_create_socket()
        guard newSocket != SRT_INVALID_SOCK else { return false }
        configure(newSocket, passphrase: passphrase)
        var timeout: Int32 = 3000
        _ = srt_setsockflag(newSocket, SRTO_CONNTIMEO, &timeout, Int32(MemoryLayout<Int32>.size))

        let connected = Self.withAddress(host: host, port: port, passive: false) { address, length in
            srt_connect(newSocket, address, length) != SRT_ERROR
        }
        guard connected else {
            srt_close(newSocket)
            return false
        }
        lock.lock()
        socket = newSocket
        pending = Data()
        lock.unlock()
        return true
    }

    /// Espera o OBS ligar na `port` (plano B). Bloqueia até alguém conectar ou `close()`.
    func listen(port: Int) -> Bool {
        close()
        let server = srt_create_socket()
        guard server != SRT_INVALID_SOCK else { return false }
        configure(server, passphrase: nil)
        var yes: Int32 = 1
        _ = srt_setsockflag(server, SRTO_REUSEADDR, &yes, Int32(MemoryLayout<Int32>.size))
        let bound = Self.withAddress(host: "0.0.0.0", port: port, passive: true) { address, length in
            srt_bind(server, address, length) != SRT_ERROR
        }
        guard bound, srt_listen(server, 1) != SRT_ERROR else {
            srt_close(server)
            return false
        }
        lock.lock()
        listenSocket = server
        lock.unlock()

        let client = srt_accept(server, nil, nil)
        lock.lock()
        if listenSocket == server {
            listenSocket = SRT_INVALID_SOCK
        }
        lock.unlock()
        srt_close(server)
        guard client != SRT_INVALID_SOCK else { return false }
        lock.lock()
        socket = client
        pending = Data()
        lock.unlock()
        return true
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard socket != SRT_INVALID_SOCK else { return false }
        return srt_getsockstate(socket) == SRTS_CONNECTED
    }

    /// Manda pacotes MPEG-TS. Devolve false se a conexão caiu.
    @discardableResult
    func send(_ packets: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard socket != SRT_INVALID_SOCK else { return false }
        pending.append(packets)
        while pending.count >= Self.messageSize {
            let chunk = pending.prefix(Self.messageSize)
            let sent = chunk.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return SRT_ERROR }
                return srt_sendmsg(socket, base.assumingMemoryBound(to: CChar.self), Int32(chunk.count), -1, 0)
            }
            pending.removeFirst(Self.messageSize)
            if sent == SRT_ERROR {
                srt_close(socket)
                socket = SRT_INVALID_SOCK
                pending = Data()
                return false
            }
        }
        return true
    }

    func close() {
        lock.lock()
        let oldSocket = socket
        let oldListener = listenSocket
        socket = SRT_INVALID_SOCK
        listenSocket = SRT_INVALID_SOCK
        pending = Data()
        lock.unlock()
        if oldSocket != SRT_INVALID_SOCK {
            srt_close(oldSocket)
        }
        if oldListener != SRT_INVALID_SOCK {
            srt_close(oldListener)
        }
    }

    deinit {
        close()
    }

    // MARK: - Ajudantes

    private func configure(_ target: SRTSOCKET, passphrase: String?) {
        var live = SRTT_LIVE
        _ = srt_setsockflag(target, SRTO_TRANSTYPE, &live, Int32(MemoryLayout<SRT_TRANSTYPE>.size))
        var latency = Self.latencyMs
        _ = srt_setsockflag(target, SRTO_LATENCY, &latency, Int32(MemoryLayout<Int32>.size))
        var yes: Int32 = 1
        _ = srt_setsockflag(target, SRTO_SENDER, &yes, Int32(MemoryLayout<Int32>.size))
        if let passphrase, !passphrase.isEmpty {
            var keyLength: Int32 = 16
            _ = srt_setsockflag(target, SRTO_PBKEYLEN, &keyLength, Int32(MemoryLayout<Int32>.size))
            _ = passphrase.withCString { text in
                srt_setsockflag(target, SRTO_PASSPHRASE, text, Int32(strlen(text)))
            }
        }
    }

    /// Resolve `host:port` (IPv4) e chama `body` com o endereço.
    private static func withAddress(host: String, port: Int, passive: Bool, _ body: (UnsafePointer<sockaddr>, Int32) -> Bool) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = passive ? AI_PASSIVE : 0
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(result) }
        guard let address = first.pointee.ai_addr else { return false }
        return body(address, Int32(first.pointee.ai_addrlen))
    }
}
