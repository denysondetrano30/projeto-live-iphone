import Foundation
import Network

/// Anuncia o iPhone na rede local (Bonjour), do mesmo jeito que uma impressora aparece sozinha.
///
/// A fonte "Celular (Projeto Live)" do OBS procura por `_projetolive._tcp` e encontra o nome
/// da câmera, o endereço do iPhone e a porta do vídeo (SRT), que vai no registro TXT.
final class Announcer {
    static let serviceType = "_projetolive._tcp"

    private let queue = DispatchQueue(label: "projetolive.bonjour")
    private var listener: NWListener?
    private let cameraName: String
    private let srtPort: Int
    private let appVersion: String

    init(cameraName: String, srtPort: Int, appVersion: String) {
        self.cameraName = cameraName
        self.srtPort = srtPort
        self.appVersion = appVersion
    }

    func start() {
        queue.async { [weak self] in
            self?.startListener()
        }
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            // Porta qualquer: ela só serve para o anúncio e para um "olá" de conferência.
            let listener = try NWListener(using: .tcp)
            let txt = NWTXTRecord([
                "app": "projeto-live",
                "srt": String(srtPort),
                "v": appVersion
            ])
            listener.service = NWListener.Service(
                name: cameraName,
                type: Self.serviceType,
                domain: nil,
                txtRecord: txt
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.sayHello(on: connection)
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

    private func restartLater() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startListener()
        }
    }

    private func sayHello(on connection: NWConnection) {
        connection.start(queue: queue)
        let hello = "{\"app\":\"projeto-live\",\"name\":\"\(cameraName)\",\"srt\":\(srtPort)}\n"
        connection.send(content: Data(hello.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
