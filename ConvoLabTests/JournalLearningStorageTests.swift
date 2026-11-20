import Foundation
import PlaygroundEngine
import XCTest

final class JournalLearningStorageTests: XCTestCase {
    func testLearnedFilesAreExcludedFromBackup() throws {
        try withLearnedFiles { directory, files in
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
            XCTAssertTrue(files.contains { $0.lastPathComponent == "confirmed.json" })
            XCTAssertGreaterThan(files.count, 1)
        }
    }

    func testLearnedFilesUseDeviceDataProtection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator does not expose file-protection attributes; run this assertion on a device.")
        #else
        try withLearnedFiles { directory, files in
            for url in [directory] + files {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            }
        }
        #endif
    }

    private func withLearnedFiles(_ check: (URL, [URL]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try PlaygroundEngine(learningDirectory: directory)
        _ = try engine.convert(#"{"reading":"あめ","expanded":true}"#)
        XCTAssertTrue(try engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try check(directory, files)
    }
}
