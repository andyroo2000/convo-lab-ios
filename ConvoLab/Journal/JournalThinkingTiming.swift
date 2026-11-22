import Foundation

nonisolated enum JournalThinkingTiming {
    static func frame(elapsed: Double, slot: Int) -> (turn: Int, opacity: Double) {
        let first = Double(slot + 1) * 3
        let later = max(0, elapsed - first)
        let turn = elapsed < first ? 0 : 1 + Int(later / 9)
        let progress = turn == 0 ? elapsed / first : later.truncatingRemainder(dividingBy: 9) / 9
        let fade = max(0, min(1, min(progress / 0.15, (1 - progress) / 0.15)))
        return (turn, fade * fade * (3 - 2 * fade))
    }

    static func dot(elapsed: Double, index: Int) -> Double {
        let phase = elapsed.truncatingRemainder(dividingBy: 2.85) / 2.85
        let fadeIn = max(0, min(1, (phase - (0.03 + Double(index) * 0.19)) / 0.06))
        let fadeOut = max(0, min(1, (1 - phase) / 0.22))
        return 0.15 + 0.65 * min(fadeIn, fadeOut)
    }
}
