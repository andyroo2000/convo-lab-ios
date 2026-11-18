import SwiftUI
import XCTest
@testable import ConvoLab

@MainActor
final class JournalTypingCoordinatorTests: XCTestCase {
    private let settings = JournalTypingSettings(label: "Journal entry", font: "KleeOne-SemiBold", size: 20, lines: 4, enabled: true)

    func testTypingRoundTripsWithoutInvalidatingInFlightChanges() {
        var text = "  昨日\n"
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }), height: .constant(200))
        coordinator.configure(text: text, settings: settings)
        let revision = coordinator.revision
        coordinator.receiveChange(["text": "  昨日は\n", "revision": NSNumber(value: revision)])
        coordinator.configure(text: text, settings: settings)
        coordinator.receiveChange(["text": "  昨日は映画\n", "revision": NSNumber(value: Double(revision))])
        XCTAssertEqual(text, "  昨日は映画\n")
        XCTAssertEqual(coordinator.revision, revision)
        let larger = JournalTypingSettings(label: "Journal entry", font: "KleeOne-SemiBold", size: 28, lines: 4, enabled: true)
        coordinator.configure(text: text, settings: larger)
        XCTAssertEqual(coordinator.revision, revision, "Appearance changes must not invalidate pending input")
    }

    func testExternalReplacementRejectsOldDocumentKeystrokes() {
        var text = "Old entry"
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }), height: .constant(200))
        coordinator.configure(text: text, settings: settings)
        let oldRevision = coordinator.revision
        text = "Different entry"
        coordinator.configure(text: text, settings: settings)
        coordinator.receiveChange(["text": "Old entry with delayed input", "revision": oldRevision])
        XCTAssertEqual(text, "Different entry")
        coordinator.receiveChange(["text": "Different entry edited", "revision": coordinator.revision])
        XCTAssertEqual(text, "Different entry edited")
    }

    func testOnlyBundledJournalPageCanUseTheBridge() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "journal-typing", withExtension: "html"))
        XCTAssertTrue(JournalTypingCoordinator.isEditorURL(editor))
        XCTAssertFalse(JournalTypingCoordinator.isEditorURL(editor.deletingLastPathComponent().appendingPathComponent("typing-playground.html")))
        XCTAssertFalse(JournalTypingCoordinator.isEditorURL(URL(fileURLWithPath: "/tmp/journal-typing.html")))
        XCTAssertFalse(JournalTypingCoordinator.isEditorURL(URL(string: "https://convo-lab.com")))
        XCTAssertFalse(JournalTypingCoordinator.isEditorURL(nil))
    }
}
