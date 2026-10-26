import Foundation

extension StudyStore {
    @discardableResult
    func beginLessonSessionPresentation(
        presentationID: UUID = UUID(),
        cohortID: String? = nil,
        pileID: String? = nil
    ) -> Bool {
        if lessonSessionIsPresented {
            return activeLessonPresentationID == presentationID
        }
        studySurfaceRevision += 1
        lessonSessionIsPresented = true
        activeLessonPresentationID = presentationID
        activeLessonCohortID = cohortID
        activePileID = pileID
        sessionLoadingService.invalidate()
        dueActivationScheduler.cancel()
        cards = []
        sessionInitialCardCount = 0
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        return true
    }

}
