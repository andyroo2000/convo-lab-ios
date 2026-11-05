import Foundation

extension StudyPileCatalog {
    mutating func apply(_ update: StudyPileUpdate, id: String, pileID: String?) {
        piles = piles.map { pile in
            guard pile.id == (pileID ?? id) else { return pile }
            return pile.applying(update, chapterID: pileID == nil ? nil : id)
        }
    }
}

private extension StudyPile {
    func applying(_ update: StudyPileUpdate, chapterID: String?) -> Self {
        let item = chapterID == nil ? summary.applying(update) : summary
        return Self(
            id: id, title: item.title, position: item.position, isActive: item.isActive,
            sourceReference: sourceReference, newCount: newCount,
            readyCount: readyCount, introducedCount: introducedCount,
            chapters: chapters.map { $0.id == chapterID ? $0.applying(update) : $0 }
        )
    }
}

private extension StudyPileChapter {
    func applying(_ update: StudyPileUpdate) -> Self {
        Self(
            id: id, title: update.title ?? title, position: update.position ?? position,
            isActive: update.isActive ?? isActive, sourceReference: sourceReference,
            newCount: newCount, readyCount: readyCount, introducedCount: introducedCount
        )
    }
}
