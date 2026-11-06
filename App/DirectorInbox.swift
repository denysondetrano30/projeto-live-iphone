import Foundation

/// Aviso do diretor (como "Abre" ou "Foca no pregador"), mostrado grande na tela.
struct DirectorCommand: Identifiable {
    let id = UUID()
    let number: UInt32
    let text: String
    /// Responde "Entendi" ao OBS pelo mesmo caminho por onde o aviso chegou (Wi-Fi ou cabo).
    let reply: () -> Void
}

/// Guarda o aviso do diretor que está na tela. Um aviso novo substitui o anterior.
final class DirectorInbox: ObservableObject {
    @Published private(set) var current: DirectorCommand?

    /// Chamado pelos canais de controle, em qualquer fila.
    func receive(number: UInt32, text: String, reply: @escaping () -> Void) {
        let command = DirectorCommand(number: number, text: text, reply: reply)
        DispatchQueue.main.async {
            self.current = command
        }
    }

    /// O operador tocou em "Entendi".
    func acknowledge() {
        current?.reply()
        current = nil
    }

    /// Lê uma linha "CMD <número> <texto>". Devolve nil se não for um aviso.
    static func parse(_ line: String) -> (number: UInt32, text: String)? {
        guard line.hasPrefix("CMD ") else { return nil }
        let parts = line.dropFirst(4).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = UInt32(parts[0]) else { return nil }
        let text = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (number: number, text: text)
    }
}
