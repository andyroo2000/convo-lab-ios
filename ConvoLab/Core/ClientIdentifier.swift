import Foundation
import Security

enum ClientIdentifier {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func ulid(date: Date = .now) -> String {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        var timestamp = milliseconds
        var prefix = Array(repeating: Character("0"), count: 10)
        for index in stride(from: 9, through: 0, by: -1) {
            prefix[index] = alphabet[Int(timestamp & 31)]
            timestamp >>= 5
        }

        var randomBytes = [UInt8](repeating: 0, count: 10)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(status == errSecSuccess, "Unable to generate secure random bytes")

        var suffix = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in randomBytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                suffix.append(alphabet[Int((buffer >> bits) & 31)])
            }
        }

        return String(prefix) + suffix
    }

    static func deviceID(defaults: UserDefaults = .standard) -> String {
        let key = "convolab.device-id"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
}

