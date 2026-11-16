#if DEBUG
import Foundation

nonisolated enum JournalAudioNavigationFixture {
    static var response: String {
        let sampleCount = 8000 * 60
        var wav = Data("RIFF".utf8)
        append(UInt32(36 + sampleCount), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(8000), to: &wav)
        append(UInt32(8000), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(8), to: &wav)
        wav.append(Data("data".utf8))
        append(UInt32(sampleCount), to: &wav)
        wav.append(Data(repeating: 128, count: sampleCount))
        return "{\"data\":{\"audioBase64\":\"\(wav.base64EncodedString())\",\"sentences\":[]}}"
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
#endif
