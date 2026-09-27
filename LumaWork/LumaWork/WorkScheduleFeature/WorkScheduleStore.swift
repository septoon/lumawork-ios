import Foundation
import Observation

private struct WorkScheduleSnapshot: Codable {
    let journals: [WorkScheduleJournal]
    let schedulesByJournalID: [String: WorkSchedule]
}

@MainActor
@Observable
final class WorkScheduleStore {
    private let service = SimpleOneRequestsService()
    private let cacheKey: String
    private var journalLoadID = UUID()
    private var scheduleLoadID = UUID()
    private var schedulesByJournalID: [String: WorkSchedule] = [:]

    private(set) var journals: [WorkScheduleJournal] = []
    private(set) var selectedCityName = ""
    private(set) var selectedYear = 0
    private(set) var selectedMonth = 0
    private(set) var didBootstrap = false
    var isLoadingJournals = false
    var isLoadingSchedule = false
    var errorMessage: String?

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("work-schedule", userID: cacheID)
        guard let snapshot = AppOfflineSnapshotStore.load(
            WorkScheduleSnapshot.self,
            key: cacheKey
        ) else {
            return
        }
        journals = snapshot.value.journals
        schedulesByJournalID = snapshot.value.schedulesByJournalID
    }

    var cityNames: [String] {
        WorkScheduleSelection.cityNames(in: journals)
    }

    var availableYears: [Int] {
        WorkScheduleSelection.years(in: journals, cityName: selectedCityName)
    }

    var availableMonths: [Int] {
        WorkScheduleSelection.months(
            in: journals,
            cityName: selectedCityName,
            year: selectedYear
        )
    }

    var selection: WorkScheduleSelectionState {
        WorkScheduleSelectionState(
            cityName: selectedCityName,
            year: selectedYear,
            month: selectedMonth
        )
    }

    var selectedJournal: WorkScheduleJournal? {
        WorkScheduleSelection.journal(in: journals, matching: selection)
    }

    var schedule: WorkSchedule? {
        selectedJournal.flatMap { schedulesByJournalID[$0.sysID] }
    }

    var isInitialLoading: Bool {
        !didBootstrap || isLoadingJournals || isLoadingSchedule
    }

    func bootstrap(
        authKey: String?,
        profileCity: String?,
        now: Date = Date()
    ) async {
        guard !didBootstrap else { return }

        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        let currentYear = components.year ?? Calendar.current.component(.year, from: now)
        let currentMonth = components.month ?? Calendar.current.component(.month, from: now)
        applyInitialSelection(
            profileCity: profileCity,
            currentYear: currentYear,
            currentMonth: currentMonth
        )

        guard let authKey, !authKey.isEmpty else {
            errorMessage = "Войдите в SimpleOne в разделе «Заявки», чтобы открыть график работы."
            didBootstrap = true
            return
        }

        let loadID = UUID()
        journalLoadID = loadID
        isLoadingJournals = true
        errorMessage = nil
        defer {
            if journalLoadID == loadID {
                isLoadingJournals = false
            }
        }
        do {
            let loadedJournals = try await service.fetchWorkScheduleJournals(authKey: authKey)
            guard !Task.isCancelled, journalLoadID == loadID else { return }
            journals = loadedJournals
            applyInitialSelection(
                profileCity: profileCity,
                currentYear: currentYear,
                currentMonth: currentMonth
            )
            saveSnapshot()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  !AppErrorPresentation.isCancellation(error) else {
                return
            }
            guard journalLoadID == loadID else { return }
            let message = appUserFacingErrorMessage(
                error,
                fallback: "Не удалось загрузить список графиков."
            ) ?? "Не удалось загрузить список графиков."
            if journals.isEmpty {
                errorMessage = message
            } else {
                AppBannerCenter.shared.show(message, style: .error)
            }
        }
        guard journalLoadID == loadID else { return }
        isLoadingSchedule = selectedJournal != nil && schedule == nil
        didBootstrap = true
        if selectedJournal == nil, errorMessage == nil {
            errorMessage = "График за выбранный месяц не опубликован."
        }
    }

    func selectCity(_ cityName: String) {
        selectedCityName = cityName
        let years = availableYears
        if !years.contains(selectedYear), let firstYear = years.first {
            selectedYear = firstYear
        }
        let months = availableMonths
        if !months.contains(selectedMonth), let latestMonth = months.last {
            selectedMonth = latestMonth
        }
        errorMessage = nil
    }

    func selectYear(_ year: Int) {
        selectedYear = year
        let months = availableMonths
        if !months.contains(selectedMonth), let latestMonth = months.last {
            selectedMonth = latestMonth
        }
        errorMessage = nil
    }

    func selectMonth(_ month: Int) {
        selectedMonth = month
        errorMessage = nil
    }

    func loadSelectedSchedule(authKey: String?, forceRefresh: Bool = false) async {
        guard let journal = selectedJournal else {
            errorMessage = "График за выбранный месяц не опубликован."
            return
        }
        if let cachedSchedule = schedulesByJournalID[journal.sysID],
           WorkScheduleCachePolicy.canReuse(cachedSchedule, forceRefresh: forceRefresh) {
            errorMessage = nil
            return
        }
        guard let authKey, !authKey.isEmpty else {
            errorMessage = "Сессия SimpleOne не найдена."
            return
        }

        let loadID = UUID()
        scheduleLoadID = loadID
        isLoadingSchedule = true
        errorMessage = nil
        defer {
            if scheduleLoadID == loadID {
                isLoadingSchedule = false
            }
        }

        do {
            let loadedSchedule = try await service.fetchWorkSchedule(
                journal: journal,
                authKey: authKey
            )
            guard !Task.isCancelled,
                  scheduleLoadID == loadID,
                  selectedJournal?.sysID == journal.sysID else {
                return
            }
            schedulesByJournalID[journal.sysID] = loadedSchedule
            saveSnapshot()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  !AppErrorPresentation.isCancellation(error) else {
                return
            }
            guard scheduleLoadID == loadID else { return }
            let message = appUserFacingErrorMessage(
                error,
                fallback: "Не удалось загрузить график работы."
            ) ?? "Не удалось загрузить график работы."
            if schedulesByJournalID[journal.sysID] == nil {
                errorMessage = message
            } else {
                AppBannerCenter.shared.show(message, style: .error)
            }
        }
    }

    func retry(authKey: String?, profileCity: String?) async {
        if selectedJournal != nil {
            await loadSelectedSchedule(authKey: authKey, forceRefresh: true)
        } else {
            didBootstrap = false
            await bootstrap(authKey: authKey, profileCity: profileCity)
        }
    }

    private func applyInitialSelection(
        profileCity: String?,
        currentYear: Int,
        currentMonth: Int
    ) {
        let selection = WorkScheduleSelection.initial(
            journals: journals,
            profileCity: profileCity,
            currentYear: currentYear,
            currentMonth: currentMonth
        )
        selectedCityName = selection.cityName
        selectedYear = selection.year
        selectedMonth = selection.month
    }

    private func saveSnapshot() {
        AppOfflineSnapshotStore.save(
            WorkScheduleSnapshot(
                journals: journals,
                schedulesByJournalID: schedulesByJournalID
            ),
            key: cacheKey
        )
    }
}
