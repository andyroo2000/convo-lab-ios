import Foundation
import MetricKit
import OSLog

nonisolated enum NativeDiagnosticOperation: String, Sendable {
    case synchronization
    case mediaPreparation
    case mediaUpload
    case generation
    case backgroundPlayback
    case metrics
}

nonisolated enum NativeDiagnosticOutcome: String, Sendable {
    case succeeded
    case failed
    case cancelled
    case discarded
}

nonisolated enum NativeDiagnosticReason: String, Sendable {
    case applicationBackgrounded
    case applicationForegrounded
    case interruptionBegan
    case interruptionEnded
    case outputRouteLost
    case playbackStarted
    case playbackStopped
    case metricPayloadReceived
    case diagnosticPayloadReceived
}

nonisolated struct NativeDiagnosticEvent: Equatable, Sendable {
    // Deliberately typed: diagnostics cannot accept URLs, identifiers, titles,
    // free-form server errors, or other user-derived strings.
    enum Stage: String, Sendable {
        case began
        case ended
        case point
    }

    let operation: NativeDiagnosticOperation
    let stage: Stage
    let outcome: NativeDiagnosticOutcome?
    let reason: NativeDiagnosticReason?
    let itemCount: Int?
}

nonisolated protocol NativeDiagnosticsSink: Sendable {
    func record(_ event: NativeDiagnosticEvent)
}

nonisolated final class NativeDiagnosticInterval: @unchecked Sendable {
    fileprivate let operation: NativeDiagnosticOperation
    fileprivate let signpostID: OSSignpostID
    private let lock = NSLock()
    private var didEnd = false

    fileprivate init(operation: NativeDiagnosticOperation, signpostID: OSSignpostID) {
        self.operation = operation
        self.signpostID = signpostID
    }

    fileprivate func claimEnd() -> Bool {
        lock.withLock {
            guard !didEnd else { return false }
            didEnd = true
            return true
        }
    }
}

nonisolated final class NativeDiagnostics: Sendable {
    static let shared = NativeDiagnostics()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.convolab.ios"
    private let sink: (any NativeDiagnosticsSink)?
    private let syncLog: OSLog
    private let mediaLog: OSLog
    private let generationLog: OSLog
    private let playbackLog: OSLog
    private let metricsLogger: Logger
    private let metricsLog: OSLog
    private let syncLogger: Logger
    private let mediaLogger: Logger
    private let generationLogger: Logger
    private let playbackLogger: Logger

    init(sink: (any NativeDiagnosticsSink)? = nil) {
        self.sink = sink
        syncLog = OSLog(subsystem: subsystem, category: "sync")
        mediaLog = OSLog(subsystem: subsystem, category: "media")
        generationLog = OSLog(subsystem: subsystem, category: "generation")
        playbackLog = OSLog(subsystem: subsystem, category: "playback")
        metricsLogger = Logger(subsystem: subsystem, category: "metrics")
        metricsLog = OSLog(subsystem: subsystem, category: "metrics")
        syncLogger = Logger(subsystem: subsystem, category: "sync")
        mediaLogger = Logger(subsystem: subsystem, category: "media")
        generationLogger = Logger(subsystem: subsystem, category: "generation")
        playbackLogger = Logger(subsystem: subsystem, category: "playback")
    }

    func begin(
        _ operation: NativeDiagnosticOperation,
        itemCount: Int? = nil
    ) -> NativeDiagnosticInterval {
        let log = log(for: operation)
        let interval = NativeDiagnosticInterval(
            operation: operation,
            signpostID: OSSignpostID(log: log)
        )
        emitSignpost(.begin, interval: interval, outcome: nil, itemCount: itemCount)
        emit(.init(
            operation: operation,
            stage: .began,
            outcome: nil,
            reason: nil,
            itemCount: itemCount
        ))
        return interval
    }

    func end(
        _ interval: NativeDiagnosticInterval,
        outcome: NativeDiagnosticOutcome,
        itemCount: Int? = nil
    ) {
        guard interval.claimEnd() else { return }
        emitSignpost(.end, interval: interval, outcome: outcome, itemCount: itemCount)
        emit(.init(
            operation: interval.operation,
            stage: .ended,
            outcome: outcome,
            reason: nil,
            itemCount: itemCount
        ))
    }

    func record(
        _ operation: NativeDiagnosticOperation,
        reason: NativeDiagnosticReason,
        itemCount: Int? = nil
    ) {
        let event = NativeDiagnosticEvent(
            operation: operation,
            stage: .point,
            outcome: nil,
            reason: reason,
            itemCount: itemCount
        )
        emit(event)
    }

    private func log(for operation: NativeDiagnosticOperation) -> OSLog {
        switch operation {
        case .synchronization: syncLog
        case .mediaPreparation: mediaLog
        case .mediaUpload: mediaLog
        case .generation: generationLog
        case .backgroundPlayback: playbackLog
        case .metrics: metricsLog
        }
    }

    private func logger(for operation: NativeDiagnosticOperation) -> Logger {
        switch operation {
        case .synchronization: syncLogger
        case .mediaPreparation: mediaLogger
        case .mediaUpload: mediaLogger
        case .generation: generationLogger
        case .backgroundPlayback: playbackLogger
        case .metrics: metricsLogger
        }
    }

    private func emit(_ event: NativeDiagnosticEvent) {
        sink?.record(event)
        logger(for: event.operation).info(
            "event stage=\(event.stage.rawValue, privacy: .public) outcome=\(event.outcome?.rawValue ?? "none", privacy: .public) reason=\(event.reason?.rawValue ?? "none", privacy: .public) count=\(event.itemCount ?? 0, privacy: .public)"
        )
    }

    private func emitSignpost(
        _ type: OSSignpostType,
        interval: NativeDiagnosticInterval,
        outcome: NativeDiagnosticOutcome?,
        itemCount: Int?
    ) {
        let log = log(for: interval.operation)
        let outcome = (outcome?.rawValue ?? "none") as NSString
        let count = itemCount ?? 0
        switch interval.operation {
        case .synchronization:
            os_signpost(
                type,
                log: log,
                name: "Synchronization",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        case .mediaPreparation:
            os_signpost(
                type,
                log: log,
                name: "Media Preparation",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        case .mediaUpload:
            os_signpost(
                type,
                log: log,
                name: "Media Upload",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        case .generation:
            os_signpost(
                type,
                log: log,
                name: "Generation",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        case .backgroundPlayback:
            os_signpost(
                type,
                log: log,
                name: "Background Playback",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        case .metrics:
            os_signpost(
                type,
                log: log,
                name: "MetricKit Delivery",
                signpostID: interval.signpostID,
                "outcome=%{public}@ count=%{public}d",
                outcome,
                count
            )
        }
    }
}

nonisolated protocol MetricManagerControlling {
    func add(_ subscriber: any MXMetricManagerSubscriber)
    func remove(_ subscriber: any MXMetricManagerSubscriber)
}

extension MXMetricManager: MetricManagerControlling {}

nonisolated final class MetricDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber,
    @unchecked Sendable
{
    private let manager: any MetricManagerControlling
    private let diagnostics: NativeDiagnostics
    private let lock = NSLock()
    private var isStarted = false

    init(
        manager: any MetricManagerControlling,
        diagnostics: NativeDiagnostics = .shared
    ) {
        self.manager = manager
        self.diagnostics = diagnostics
    }

    @MainActor override convenience init() {
        self.init(manager: MXMetricManager.shared)
    }

    func start() {
        let shouldStart = lock.withLock {
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        if shouldStart { manager.add(self) }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard isStarted else { return false }
            isStarted = false
            return true
        }
        if shouldStop { manager.remove(self) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        diagnostics.record(
            .metrics,
            reason: .metricPayloadReceived,
            itemCount: payloads.count
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        diagnostics.record(
            .metrics,
            reason: .diagnosticPayloadReceived,
            itemCount: payloads.count
        )
    }
}
