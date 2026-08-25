import MetricKit
import XCTest
@testable import ConvoLab

final class NativeDiagnosticsTests: XCTestCase {
    func testIntervalLifecycleEmitsOneBeginAndExactlyOneEnd() {
        let sink = RecordingNativeDiagnosticsSink()
        let diagnostics = NativeDiagnostics(sink: sink)

        let interval = diagnostics.begin(.mediaPreparation, itemCount: 3)
        diagnostics.end(interval, outcome: .succeeded, itemCount: 2)
        diagnostics.end(interval, outcome: .failed, itemCount: 99)

        XCTAssertEqual(sink.events, [
            .init(
                operation: .mediaPreparation,
                stage: .began,
                outcome: nil,
                reason: nil,
                itemCount: 3
            ),
            .init(
                operation: .mediaPreparation,
                stage: .ended,
                outcome: .succeeded,
                reason: nil,
                itemCount: 2
            ),
        ])
    }

    func testPointEventsContainOnlyAllowlistedPrivacySafeMetadata() {
        let sink = RecordingNativeDiagnosticsSink()
        let diagnostics = NativeDiagnostics(sink: sink)

        diagnostics.record(
            .backgroundPlayback,
            reason: .outputRouteLost,
            itemCount: 1
        )

        let event = try! XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.operation, .backgroundPlayback)
        XCTAssertEqual(event.reason, .outputRouteLost)
        XCTAssertEqual(event.itemCount, 1)
        XCTAssertNil(event.outcome)
        XCTAssertFalse(String(describing: event).contains("@"))
        XCTAssertFalse(String(describing: event).contains("https://"))
    }

    func testMetricKitSubscriberRegistrationLifecycleIsIdempotent() {
        let manager = RecordingMetricManager()
        let subscriber = MetricDiagnosticsSubscriber(
            manager: manager,
            diagnostics: NativeDiagnostics(sink: RecordingNativeDiagnosticsSink())
        )

        subscriber.start()
        subscriber.start()
        subscriber.stop()
        subscriber.stop()

        XCTAssertEqual(manager.addCount, 1)
        XCTAssertEqual(manager.removeCount, 1)
        XCTAssertTrue(manager.addedSubscriber === subscriber)
        XCTAssertTrue(manager.removedSubscriber === subscriber)
    }

    @MainActor
    func testAudioPlayerEmitsPairedLifecycleWithoutTrackMetadata() {
        let sink = RecordingNativeDiagnosticsSink()
        let diagnostics = NativeDiagnostics(sink: sink)
        let playback = AudioPlaybackDiagnostics(diagnostics: diagnostics)

        playback.start()
        playback.interruptionBegan()
        playback.interruptionEnded(willResume: true)
        playback.stop(outcome: .succeeded)

        XCTAssertEqual(
            sink.events.map(\.stage),
            [.began, .point, .point, .point, .ended, .point, .began, .point, .point, .ended]
        )
        XCTAssertEqual(
            sink.events.filter { $0.reason == .interruptionBegan }.count,
            1
        )
        XCTAssertEqual(
            sink.events.filter { $0.reason == .interruptionEnded }.count,
            1
        )
        XCTAssertEqual(sink.events.last?.outcome, .succeeded)
        let description = String(describing: sink.events)
        XCTAssertFalse(description.contains("private-track-id"))
        XCTAssertFalse(description.contains("Private Lesson Title"))
        XCTAssertFalse(description.contains("secret-audio"))
    }
}

nonisolated final class RecordingNativeDiagnosticsSink: NativeDiagnosticsSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedEvents: [NativeDiagnosticEvent] = []

    var events: [NativeDiagnosticEvent] {
        lock.withLock { storedEvents }
    }

    func record(_ event: NativeDiagnosticEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

nonisolated private final class RecordingMetricManager: MetricManagerControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedAddCount = 0
    private var storedRemoveCount = 0
    private weak var storedAddedSubscriber: (any MXMetricManagerSubscriber)?
    private weak var storedRemovedSubscriber: (any MXMetricManagerSubscriber)?

    var addCount: Int { lock.withLock { storedAddCount } }
    var removeCount: Int { lock.withLock { storedRemoveCount } }
    var addedSubscriber: (any MXMetricManagerSubscriber)? {
        lock.withLock { storedAddedSubscriber }
    }
    var removedSubscriber: (any MXMetricManagerSubscriber)? {
        lock.withLock { storedRemovedSubscriber }
    }

    func add(_ subscriber: any MXMetricManagerSubscriber) {
        lock.withLock {
            storedAddCount += 1
            storedAddedSubscriber = subscriber
        }
    }

    func remove(_ subscriber: any MXMetricManagerSubscriber) {
        lock.withLock {
            storedRemoveCount += 1
            storedRemovedSubscriber = subscriber
        }
    }
}
