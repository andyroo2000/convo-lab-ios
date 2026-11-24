import UIKit

struct JournalHighlightFragment {
    let source: Int
    let rect: CGRect
    let optional: Bool

    /// Separate paint without changing the text, selection ranges, or tap targets.
    func paintedRect(among fragments: [JournalHighlightFragment]) -> CGRect {
        let neighbors = fragments.filter {
            $0.source != source && abs($0.rect.minY - rect.minY) < 0.5
                && abs($0.rect.maxY - rect.maxY) < 0.5
        }
        let inset = min(3, rect.width / 4)
        let left = neighbors.contains { abs($0.rect.maxX - rect.minX) < 0.5 } ? rect.minX + inset : rect.minX - 1
        let right = neighbors.contains { abs($0.rect.minX - rect.maxX) < 0.5 } ? rect.maxX - inset : rect.maxX + 1
        return CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
    }
}
