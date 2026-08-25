import Foundation
import SwiftData

extension StudyStore {
    func refreshOverview() async {
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        let settingsMutationRevision = studySettingsMutationRevision
        let refreshID = UUID()
        overviewRefreshID = refreshID
        isRefreshingOverview = true
        overviewRefreshErrorMessage = nil

        defer {
            if isCurrentActivation(userID, generation: activationGeneration),
               overviewRefreshID == refreshID {
                isRefreshingOverview = false
            }
        }

        do {
            let refreshed: StudyOverview = try await api.request("/api/study/overview")
            guard isCurrentActivation(userID, generation: activationGeneration),
                  overviewRefreshID == refreshID else { return }
            let responseSettings = StudySettingsPolicy.settings(
                from: refreshed,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            let canPublishResponseSettings = studySettingsMutationRevision
                == settingsMutationRevision
            let appliedSettings = canPublishResponseSettings
                ? responseSettings
                : studySettings ?? responseSettings
            setOverview(StudySettingsPolicy.applying(
                appliedSettings,
                to: refreshed,
                preservingJLPTMasteryFrom: overview
            ))
            if canPublishResponseSettings {
                studySettings = responseSettings
            }
        } catch {
            guard isCurrentActivation(userID, generation: activationGeneration),
                  overviewRefreshID == refreshID else { return }
            overviewRefreshErrorMessage = error.localizedDescription
        }
    }

    func refreshStudySettings() async {
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        let mutationRevision = studySettingsMutationRevision
        let refreshID = UUID()
        studySettingsRefreshID = refreshID
        do {
            let response: StudySettings = try await api.request("/api/study/settings")
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsRefreshID == refreshID,
               studySettingsMutationRevision == mutationRevision
            else { return }
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                setOverview(StudySettingsPolicy.applying(resolvedResponse, to: current))
            }
            studySettingsErrorMessage = nil
        } catch {
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsRefreshID == refreshID,
               studySettingsMutationRevision == mutationRevision
            else { return }
            studySettingsErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateNewCardsPerDay(_ value: Int) async -> Bool {
        await updateStudySettings(
            newCardsPerDay: value,
            lessonBatchSize: studySettings?.lessonBatchSize ?? overview?.lessonBatchSize ?? 5
        )
    }

    @discardableResult
    func updateStudySettings(
        newCardsPerDay: Int,
        lessonBatchSize: Int,
        reviewTimeBudgetMinutes: Int? = nil
    ) async -> Bool {
        guard
            let userID = activeUserID,
            StudySettingsPolicy.accepts(
                newCardsPerDay: newCardsPerDay,
                lessonBatchSize: lessonBatchSize,
                reviewTimeBudgetMinutes: reviewTimeBudgetMinutes
            )
        else { return false }
        let activationGeneration = accountActivationGeneration
        studySettingsMutationRevision += 1
        let updateID = UUID()
        studySettingsUpdateID = updateID
        isUpdatingStudySettings = true
        studySettingsErrorMessage = nil
        defer {
            if isCurrentActivation(userID, generation: activationGeneration),
               studySettingsUpdateID == updateID
            {
                isUpdatingStudySettings = false
                studySettingsUpdateID = nil
            }
        }

        do {
            let response: StudySettings = try await api.request(
                "/api/study/settings",
                method: "PATCH",
                body: UpdateStudySettingsRequest(
                    newCardsPerDay: newCardsPerDay,
                    lessonBatchSize: lessonBatchSize,
                    reviewTimeBudgetMinutes: reviewTimeBudgetMinutes
                )
            )
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsUpdateID == updateID else { return false }
            studySettingsMutationRevision += 1
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                requestedReviewTimeBudget: reviewTimeBudgetMinutes,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                setOverview(StudySettingsPolicy.applying(resolvedResponse, to: current))
            }
            // The server may now admit a different set of new cards and build a
            // different offline reserve. Force the next Study-page entry to refresh.
            lastSyncAt = nil
            lastSessionRefreshAt = nil
            return true
        } catch {
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsUpdateID == updateID else { return false }
            studySettingsErrorMessage = error.localizedDescription
            return false
        }
    }

    func loadCachedOverview(userID: Int) {
        var descriptor = FetchDescriptor<LocalStudyOverviewSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard let snapshot = try? overviewContext.fetch(descriptor).first else { return }
        overviewSnapshot = snapshot
        guard let cachedOverview = try? StorageCodec.decoder.decode(
                StudyOverview.self,
                from: snapshot.payload
            ) else { return }

        overview = cachedOverview
        studySettings = StudySettingsPolicy.settings(
            from: cachedOverview,
            fallbackReviewTimeBudget: cachedOverview.reviewTimeBudgetMinutes ?? 90
        )
    }

    func setOverview(
        _ value: StudyOverview,
        persistImmediately: Bool = true
    ) {
        overview = value
        guard let userID = activeUserID else { return }

        do {
            let payload = try StorageCodec.encoder.encode(value)
            let snapshot: LocalStudyOverviewSnapshot
            if let overviewSnapshot, overviewSnapshot.userID == userID {
                snapshot = overviewSnapshot
            } else {
                var descriptor = FetchDescriptor<LocalStudyOverviewSnapshot>(
                    predicate: #Predicate { $0.userID == userID }
                )
                descriptor.fetchLimit = 1
                if let existing = try overviewContext.fetch(descriptor).first {
                    snapshot = existing
                } else {
                    snapshot = LocalStudyOverviewSnapshot(userID: userID, payload: payload)
                    overviewContext.insert(snapshot)
                }
                overviewSnapshot = snapshot
            }
            snapshot.payload = payload
            snapshot.updatedAt = .now
            if persistImmediately {
                persistPendingOverviewSnapshot()
            } else {
                scheduleOverviewSnapshotSave()
            }
        } catch {
            // The snapshot is a disposable presentation cache. Study cards and
            // queued reviews remain durable even if this best-effort save fails.
            overviewContext.rollback()
            overviewSnapshot = nil
        }
    }

    private func scheduleOverviewSnapshotSave() {
        overviewSnapshotSaveTask?.cancel()
        overviewSnapshotSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.persistPendingOverviewSnapshot()
        }
    }

    func persistPendingOverviewSnapshot() {
        overviewSnapshotSaveTask?.cancel()
        overviewSnapshotSaveTask = nil
        guard overviewContext.hasChanges else { return }
        do {
            try overviewContext.save()
        } catch {
            // This dedicated context contains only the disposable presentation
            // snapshot, so rollback can never discard cards or outbox mutations.
            overviewContext.rollback()
            overviewSnapshot = nil
        }
    }

}
