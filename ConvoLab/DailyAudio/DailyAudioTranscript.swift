import Foundation

enum DailyAudioTranscript {
    private static let timingDriftToleranceMilliseconds = 1_000.0
    private static let subtitleLeadMilliseconds = 250.0
    private static let subtitleHoldMilliseconds = 1_000.0

    static func currentSpokenUnit(
        in track: DailyAudioTrack,
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> DailyAudioScriptUnit? {
        guard
            let units = track.scriptUnitsJson,
            let timings = track.timingData,
            !units.isEmpty,
            !timings.isEmpty
        else {
            return nil
        }

        let elapsedMilliseconds = elapsedSeconds * 1_000
        for timing in normalized(timings, durationSeconds: durationSeconds).reversed() {
            guard units.indices.contains(timing.unitIndex) else { continue }
            let unit = units[timing.unitIndex]
            guard unit.type == "L2" else { continue }
            if elapsedMilliseconds >= timing.startTime - subtitleLeadMilliseconds,
               elapsedMilliseconds < timing.endTime + subtitleHoldMilliseconds {
                return unit
            }
        }
        return nil
    }

    private static func normalized(
        _ timings: [DailyAudioTiming],
        durationSeconds: Double?
    ) -> [DailyAudioTiming] {
        guard
            let durationSeconds,
            durationSeconds > 0,
            let finalEnd = timings.map(\.endTime).max(),
            finalEnd > 0
        else {
            return timings
        }

        let targetEnd = durationSeconds * 1_000
        guard abs(finalEnd - targetEnd) > timingDriftToleranceMilliseconds else {
            return timings
        }
        let scale = targetEnd / finalEnd
        return timings.map {
            DailyAudioTiming(
                unitIndex: $0.unitIndex,
                startTime: $0.startTime * scale,
                endTime: $0.endTime * scale
            )
        }
    }
}
