import Foundation

enum StorageCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(ISO8601Milliseconds.encode)
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(ISO8601Milliseconds.decode)
        return decoder
    }()
}
