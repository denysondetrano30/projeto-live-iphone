import AVFoundation
import Foundation

/// Comprime o som do microfone em AAC para ir junto com a imagem para o OBS.
///
/// Recebe o som do microfone que o iPhone estiver usando (o embutido, ou um microfone externo
/// ligado no USB-C/Lightning, como um receptor sem fio) e entrega quadros AAC prontos para o
/// MPEG-TS (com cabeçalho ADTS), cada um com o PTS no relógio do iPhone (`PhoneClock`), o mesmo
/// relógio dos quadros de vídeo. Assim o OBS toca o som junto com a imagem.
final class AACEncoder {
    /// Quadro AAC com cabeçalho ADTS e o PTS (90 kHz).
    var output: ((Data, UInt64) -> Void)?

    private static let samplesPerPacket = 1024
    private static let encoderDelay: Int64 = 2112
    /// Diferença maior que isso entre a hora do som e a contagem de amostras: recomeça a contagem.
    private static let maxDrift = 0.05

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var sampleRate: Double = 48_000
    private var channels: UInt32 = 1

    // Linha do tempo do som: hora da primeira amostra e quantas amostras já entraram e saíram.
    private var anchorSeconds: Double?
    private var samplesIn: Int64 = 0
    private var samplesOut: Int64 = 0

    /// Som novo do microfone. `silent` = manda silêncio (alguém está falando no intercom).
    func encode(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, silent: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard buffer.frameLength > 0, time.isHostTimeValid else { return }
        if !sameFormat(buffer.format) {
            setUp(for: buffer.format)
        }
        guard let converter, let outputFormat else { return }

        if silent, let channelData = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                channelData[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }

        // Hora (relógio do iPhone) da primeira amostra deste pedaço.
        let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        if let anchor = anchorSeconds {
            let expected = anchor + Double(samplesIn) / sampleRate
            if abs(expected - seconds) > Self.maxDrift {
                anchorSeconds = seconds - Double(samplesIn) / sampleRate
            }
        } else {
            anchorSeconds = seconds
        }
        samplesIn += Int64(buffer.frameLength)

        var given = false
        while true {
            let compressed = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 8,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
            )
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil {
                return
            }
            emit(compressed)
            if status != .haveData || compressed.packetCount == 0 {
                break
            }
        }
    }

    // MARK: - Ajudantes

    private func sameFormat(_ format: AVAudioFormat) -> Bool {
        guard let inputFormat else { return false }
        return inputFormat.sampleRate == format.sampleRate && inputFormat.channelCount == format.channelCount
            && inputFormat.commonFormat == format.commonFormat
    }

    private func setUp(for format: AVAudioFormat) {
        converter = nil
        inputFormat = format
        anchorSeconds = nil
        samplesIn = 0
        samplesOut = 0
        guard format.commonFormat == .pcmFormatFloat32, Self.frequencyIndex(format.sampleRate) != nil else {
            return
        }
        sampleRate = format.sampleRate
        channels = min(max(format.channelCount, 1), 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        guard let aac = AVAudioFormat(settings: settings), let newConverter = AVAudioConverter(from: format, to: aac) else {
            return
        }
        outputFormat = aac
        converter = newConverter
    }

    private func emit(_ compressed: AVAudioCompressedBuffer) {
        guard let descriptions = compressed.packetDescriptions, let anchor = anchorSeconds else { return }
        let base = compressed.data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<Int(compressed.packetCount) {
            let description = descriptions[index]
            let size = Int(description.mDataByteSize)
            guard size > 0 else { continue }
            var frame = Data(adtsHeader(payloadSize: size))
            frame.append(base + Int(description.mStartOffset), count: size)

            // O codificador AAC da Apple põe 2112 amostras de "aquecimento" na frente: tira da conta,
            // para o som não sair atrasado em relação à imagem.
            let seconds = anchor + Double(samplesOut - Self.encoderDelay) / sampleRate
            samplesOut += Int64(Self.samplesPerPacket)
            let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            output?(frame, PhoneClock.pts90k(time))
        }
    }

    /// Cabeçalho ADTS (7 bytes) de um quadro AAC-LC.
    private func adtsHeader(payloadSize: Int) -> [UInt8] {
        let length = payloadSize + 7
        let profile: UInt8 = 1 // AAC-LC (perfil 2, gravado como 2 - 1)
        let frequency = Self.frequencyIndex(sampleRate) ?? 3
        let channelConfig = UInt8(channels)
        return [
            0xFF,
            0xF1,
            (profile << 6) | (frequency << 2) | (channelConfig >> 2),
            ((channelConfig & 0x03) << 6) | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5) | 0x1F,
            0xFC
        ]
    }

    private static func frequencyIndex(_ rate: Double) -> UInt8? {
        let rates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000]
        guard let index = rates.firstIndex(of: rate) else { return nil }
        return UInt8(index)
    }
}
