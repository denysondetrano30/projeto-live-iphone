import Foundation

/// Dados lidos do QR code de uma fonte "Celular (Projeto Live)" no OBS.
///
/// Formato do QR code: `projetolive://pair?v=1&p=PORTA&k=SENHA&h=IP1,IP2&n=NOME-DA-FONTE`
struct Pairing: Codable, Equatable {
    var hosts: [String]
    var port: Int
    var key: String
    var sourceName: String

    static func parse(_ text: String) -> Pairing? {
        guard let components = URLComponents(string: text),
              components.scheme == "projetolive",
              components.host == "pair" else {
            return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        guard let port = Int(values["p"] ?? ""), port > 0, port < 65536,
              let key = values["k"], key.count >= 10,
              let hostList = values["h"] else {
            return nil
        }
        let hosts = hostList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        let name = values["n"].flatMap { $0.isEmpty ? nil : $0 } ?? "OBS"
        return Pairing(hosts: hosts, port: port, key: key, sourceName: name)
    }

    /// Tenta primeiro o endereço do PC que está na mesma rede do iPhone.
    func orderedHosts(phoneIP: String?) -> [String] {
        guard let phoneIP else { return hosts }
        let prefix = phoneIP.split(separator: ".").prefix(3).joined(separator: ".") + "."
        let sameNetwork = hosts.filter { $0.hasPrefix(prefix) }
        return sameNetwork + hosts.filter { !$0.hasPrefix(prefix) }
    }
}

/// Guarda o pareamento no aparelho, para reconectar sozinho na próxima vez.
enum PairingStore {
    private static let key = "projetolive.pairing"

    static func load() -> Pairing? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing?) {
        if let pairing, let data = try? JSONEncoder().encode(pairing) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
