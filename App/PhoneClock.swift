import CoreMedia
import Foundation

/// Relógio do iPhone usado na sincronia com o OBS.
///
/// É o mesmo relógio dos quadros da câmera (o "host time" do sistema). Cada quadro sai com o PTS
/// do MPEG-TS igual a este relógio (em 90 kHz), e o canal de controle responde `TIME` com ele (em
/// nanossegundos). Com isso o OBS sabe a hora exata, no relógio do PC, em que cada quadro foi
/// filmado, e mostra todas as câmeras com o mesmo atraso fixo.
enum PhoneClock {
    /// Agora, em nanossegundos.
    static func nowNanoseconds() -> Int64 {
        CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default).value
    }

    /// PTS do MPEG-TS (90 kHz, 33 bits) para um quadro filmado em `time`.
    static func pts90k(_ time: CMTime) -> UInt64 {
        let value = CMTimeConvertScale(time, timescale: 90_000, method: .default).value
        return UInt64(max(0, value)) & 0x1_FFFF_FFFF
    }

    /// Resposta ao `TIME <hora do PC>` do OBS: `TIME <hora do PC> <hora do iPhone>`.
    static func timeReply(_ line: String) -> String? {
        guard line.hasPrefix("TIME ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, Int64(parts[1]) != nil else { return nil }
        return "TIME \(parts[1]) \(nowNanoseconds())"
    }
}
