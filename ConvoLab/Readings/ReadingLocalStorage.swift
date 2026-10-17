import Foundation
import CryptoKit

struct ReadingSnapshot: Codable {
    var library: [Int: ReadingLibraryPage] = [:]
    var books: [String: ReadingBook] = [:]
    var documents: [String: ReadingDetail] = [:]
    var positions: [String: ReadingPosition] = [:]
    var pending: [String: ReadingPosition] = [:]
    var rejected: [String: ReadingPosition]?
    var resume: ReadingContinue?
    var recoveryMessage: String?
}

private struct ReadingPositionState: Codable {
    let positions: [String: ReadingPosition]
    let pending: [String: ReadingPosition]
    let rejected: [String: ReadingPosition]?
    let resume: ReadingContinue?
}

struct ReadingLocalStorage {
    let userID: Int
    private var directory: URL {
        Self.root.appending(path: String(userID), directoryHint: .isDirectory)
    }
    private static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Readings", directoryHint: .isDirectory)
    }

    func load() throws -> ReadingSnapshot {
        var snapshot = ReadingSnapshot()
        do { snapshot = try read(ReadingSnapshot.self, name: "library.json") ?? snapshot }
        catch { snapshot.recoveryMessage = "Saved book content could not be opened. A recovery copy was preserved." }
        do {
            if let positions = try read(ReadingPositionState.self, name: "positions.json") {
                snapshot.positions = positions.positions
                snapshot.pending = positions.pending
                snapshot.rejected = positions.rejected
                snapshot.resume = positions.resume
            }
        } catch { snapshot.recoveryMessage = "Saved reading positions could not be opened. A recovery copy was preserved." }
        return snapshot
    }

    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch {
            // Preserve unreadable state for recovery before allowing any later save.
            let bytes = try Data(contentsOf: url)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let backup = directory.appending(path: "\(name).recovery-\(digest)")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            throw error
        }
    }

    func save(_ snapshot: ReadingSnapshot) throws {
        try write(snapshot, name: "library.json")
        try savePositions(snapshot)
    }

    func savePositions(_ snapshot: ReadingSnapshot) throws {
        let state = ReadingPositionState(positions: snapshot.positions, pending: snapshot.pending, rejected: snapshot.rejected, resume: snapshot.resume)
        try write(state, name: "positions.json")
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func resource(key: String) throws -> Data? {
        let url = resourceURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func saveResource(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: resourceURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try pruneResources()
    }

    func removeResource(key: String) throws {
        let url = resourceURL(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func pruneResources() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.lastPathComponent.count == 64 }
            .map { ($0, try $0.resourceValues(forKeys: keys)) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (url, values) in files {
            guard total > 200 * 1024 * 1024 else { break }
            try FileManager.default.removeItem(at: url)
            total -= values.fileSize ?? 0
        }
    }

    private func resourceURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    static func remove(userID: Int) throws {
        let directory = root.appending(path: String(userID), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
