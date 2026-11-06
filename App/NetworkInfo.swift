import Darwin
import Foundation

enum NetworkInfo {
    /// Endereço IPv4 do iPhone no Wi-Fi (interface en0), por exemplo "192.168.0.15".
    /// Devolve `nil` se o Wi-Fi estiver desligado ou sem rede.
    static func wifiIPv4() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let first = firstAddress else {
            return nil
        }
        defer { freeifaddrs(firstAddress) }

        var result: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    result = String(cString: host)
                }
            }
            cursor = interface.ifa_next
        }
        return result
    }
}
