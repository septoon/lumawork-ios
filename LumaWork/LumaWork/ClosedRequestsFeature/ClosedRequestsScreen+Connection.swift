import Foundation
import OSLog
import SwiftUI

extension ClosedRequestsScreen {
    var closedArchiveProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppLoadingView(title: "Обновляю закрытые заявки")
            HStack(spacing: 10) {
                ProgressView(value: closedArchiveProgressFraction)
                    .tint(AppTheme.primaryTint)
                Text("\(closedArchiveProgressPercent)%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
            }
            Text(closedArchiveProgressText.isEmpty ? "Готовлю XLSX-архив SimpleOne." : closedArchiveProgressText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
        }
    }

    var simpleOneConnectionCard: some View {
        @Bindable var simpleOneBinding = simpleOneStore
        return AppCard {
            if simpleOneStore.isAuthorized {
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.secondaryTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            Text(simpleOneStore.currentUser?.displayName.isEmpty == false ? simpleOneStore.currentUser?.displayName ?? "SimpleOne" : "SimpleOne")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                            Text(lastSimpleOneUpdateText)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Информация об архиве")

                    if simpleOneStore.isLoading || isRefreshingSimpleOneData || store.isImporting || store.isDeleting || store.isSynchronizingClosedRequests || isRefreshingClosedRequestsArchive {
                        ProgressView()
                            .tint(AppTheme.primaryTint)
                    } else {
                        Button {
                            Task {
                                await refreshAllSimpleOneData()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.headline.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.primaryTint)
                        .background(AppTheme.secondaryTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Обновить заявки SimpleOne")
                        .disabled(isRefreshingSimpleOneData || store.isImporting || store.isDeleting || store.isSynchronizingClosedRequests || isRefreshingClosedRequestsArchive)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    AppSectionHeader(
                        title: "Вход в SimpleOne",
                        caption: "Пароль используется только для входа."
                    )

                    if let errorMessage = simpleOneStore.errorMessage {
                        AppNoticeBanner(
                            text: errorMessage,
                            tint: AppTheme.dangerTint,
                            isCritical: true
                        )
                    }

                    TextField("Логин", text: $simpleOneBinding.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .padding(12)
                        .background(AppTheme.buttonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    SecureField("Пароль", text: $simpleOnePassword)
                        .textContentType(.password)
                        .padding(12)
                        .background(AppTheme.buttonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        Task {
                            await simpleOneStore.signIn(password: simpleOnePassword)
                            if simpleOneStore.isAuthorized {
                                simpleOnePassword = ""
                                await refreshAllSimpleOneData(refreshActive: false)
                            }
                        }
                    } label: {
                        HStack {
                            if simpleOneStore.isSigningIn || isRefreshingSimpleOneData || store.isImporting || isRefreshingClosedRequestsArchive {
                                ProgressView()
                                    .tint(AppTheme.ink)
                            }
                            Text(simpleOneStore.isSigningIn || isRefreshingSimpleOneData || store.isImporting || isRefreshingClosedRequestsArchive ? "Загрузка..." : "Войти и загрузить")
                        }
                    }
                    .buttonStyle(AppActionButtonStyle())
                    .disabled(simpleOneStore.isSigningIn || isRefreshingSimpleOneData || store.isImporting || isRefreshingClosedRequestsArchive)
                }
            }
        }
    }

    var lastSimpleOneUpdateText: String {
        guard let lastUpdatedAt = simpleOneStore.lastUpdatedAt else {
            return "Заявки еще не обновлялись."
        }
        return "Обновлено \(Self.simpleOneUpdatedAtFormatter.string(from: lastUpdatedAt))"
    }

    func refreshSimpleOneRequests(
        refreshActive: Bool = true,
        showsSuccessNotice: Bool = true,
        forceCommentsRefresh: Bool = true
    ) async {
        guard simpleOneStore.isAuthorized else {
            simpleOneStore.errorMessage = SimpleOneServiceError.missingCredentials.errorDescription
            return
        }

        isRefreshingSimpleOneData = true
        store.errorMessage = nil
        store.notice = nil
        defer { isRefreshingSimpleOneData = false }

        async let commentsRefresh: Void = clientCommentsStore.refresh(force: forceCommentsRefresh)
        if refreshActive {
            await simpleOneStore.refresh()
        }
        await commentsRefresh
        rebuildActiveRequestItems()

        guard simpleOneStore.errorMessage == nil,
              clientCommentsStore.errorMessage == nil else {
            return
        }

        if showsSuccessNotice {
            store.notice = "Заявки SimpleOne обновлены."
        }
    }

    func refreshAllSimpleOneData(refreshActive: Bool = true) async {
        await refreshSimpleOneRequests(
            refreshActive: refreshActive,
            showsSuccessNotice: false
        )
        guard simpleOneStore.errorMessage == nil else { return }

        await refreshClosedRequestsIncrementally()

        if store.errorMessage == nil {
            store.notice = "Активные и закрытые заявки обновлены."
        }
    }

    func refreshClosedRequestsIncrementally() async {
        do {
            try await store.waitForClosedRequestsSyncAvailability()
        } catch is CancellationError {
            return
        } catch {
            store.errorMessage = appUserFacingErrorMessage(error)
            return
        }

        if store.snapshot == nil || store.needsMerchantTINRepair {
            await refreshClosedRequestsArchiveFromSimpleOne()
            return
        }

        _ = await synchronizeClosedRequestsAutomatically(
            scope: .narrow,
            waitsForCurrentSync: true,
            reportsErrors: true
        )
        guard store.errorMessage == nil else { return }

        if let userID = simpleOneStore.currentUser?.sysID,
           store.shouldRunWideClosedRequestsSync(userID: userID) {
            _ = await synchronizeClosedRequestsAutomatically(
                scope: .wide,
                waitsForCurrentSync: true,
                reportsErrors: true
            )
        }
    }

    func refreshClosedRequestsArchiveFromSimpleOne() async {
        guard !store.isDeleting, !store.isImporting else { return }
        guard simpleOneStore.isAuthorized else {
            simpleOneStore.errorMessage = SimpleOneServiceError.missingCredentials.errorDescription
            return
        }

        isRefreshingClosedRequestsArchive = true
        closedArchiveProgressFraction = 0.08
        closedArchiveProgressText = "Готовлю XLSX-выгрузку SimpleOne."
        store.errorMessage = nil
        store.notice = nil
        defer {
            isRefreshingClosedRequestsArchive = false
            closedArchiveProgressFraction = 0
            closedArchiveProgressText = ""
        }

        do {
            let narrowHead = try? await simpleOneStore.fetchClosedSyncHead(scope: .narrow)
            let wideHead = try? await simpleOneStore.fetchClosedSyncHead(scope: .wide)
            closedArchiveProgressFraction = 0.22
            closedArchiveProgressText = "Жду готовый XLSX в SimpleOne."
            let exportedFile = try await simpleOneStore.exportClosedRequestsXLSXForCurrentUser()
            closedArchiveProgressFraction = 0.68
            closedArchiveProgressText = "Скачал XLSX. Разбираю таблицу."
            await store.importSpreadsheet(
                data: exportedFile.data,
                fileName: exportedFile.fileName
            )
            let baselineUserID = narrowHead?.userID ?? wideHead?.userID
            let baselineUsersMatch = narrowHead == nil
                || wideHead == nil
                || narrowHead?.userID == wideHead?.userID
            if let baselineUserID, baselineUsersMatch, store.errorMessage == nil {
                await store.setClosedRequestsSyncBaseline(
                    userID: baselineUserID,
                    narrow: narrowHead?.cursor,
                    wide: wideHead?.cursor
                )
            }
            if store.errorMessage == nil {
                store.markMerchantTINRepairCompleted()
            }
            closedArchiveProgressFraction = 0.95
            closedArchiveProgressText = "Сохраняю локальный архив."
            if store.errorMessage == nil {
                closedArchiveProgressFraction = 1
                closedArchiveProgressText = "Готово."
                requestsMode = .closed
            }
        } catch {
            store.notice = nil
            store.errorMessage = appUserFacingErrorMessage(error)
        }
    }

    var closedRequestsAutomaticSyncTaskID: String {
        "\(simpleOneStore.isAuthorized)|\(simpleOneStore.currentUser?.sysID ?? "")"
    }

    func runClosedRequestsAutomaticSyncLoop() async {
        guard simpleOneStore.isAuthorized else { return }

        while store.isLoadingSnapshot, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }

        while simpleOneStore.isAuthorized, !Task.isCancelled {
            if simpleOneStore.isLoading || isRefreshingSimpleOneData {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                continue
            }

            if store.snapshot == nil || store.needsMerchantTINRepair {
                await refreshClosedRequestsArchiveFromSimpleOne()
                if store.snapshot == nil {
                    do {
                        try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }
            }

            let changedCount = await synchronizeClosedRequestsAutomatically(scope: .narrow)
            if changedCount > 0 {
                closedRequestsNoChangeStreak = 0
            } else {
                closedRequestsNoChangeStreak += 1
            }

            if let userID = simpleOneStore.currentUser?.sysID,
               store.shouldRunWideClosedRequestsSync(userID: userID) {
                _ = await synchronizeClosedRequestsAutomatically(scope: .wide)
            }

            let delay: UInt64
            switch closedRequestsNoChangeStreak {
            case 0:
                delay = 60
            case 1 ... 2:
                delay = 120
            default:
                delay = 300
            }
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    @discardableResult
    func synchronizeClosedRequestsAutomatically(
        scope: ClosedRequestsSyncScope,
        waitsForCurrentSync: Bool = false,
        reportsErrors: Bool = false
    ) async -> Int {
        guard simpleOneStore.isAuthorized,
              !simpleOneStore.isLoading,
              !isRefreshingSimpleOneData,
              !isRefreshingClosedRequestsArchive,
              !store.isImporting,
              !store.isDeleting else {
            return 0
        }

        do {
            let changedCount = try await store.synchronizeFromSimpleOne(
                simpleOneStore,
                scope: scope,
                waitsForCurrentSync: waitsForCurrentSync
            )
            return changedCount
        } catch is CancellationError {
            return 0
        } catch {
            Logger(subsystem: "LumaWork", category: "ClosedRequestsSync")
                .error("Automatic closed requests sync failed: \(error.localizedDescription, privacy: .public)")
            if reportsErrors {
                store.errorMessage = appUserFacingErrorMessage(error)
            }
            return 0
        }
    }

    var activeRequests: [SimpleOneRequestRecord] {
        simpleOneStore.activeRequests
    }

    var closedArchiveProgressPercent: Int {
        min(100, max(0, Int((closedArchiveProgressFraction * 100).rounded())))
    }

    var closedRequests: [ClosedRequestRecord] {
        closedRequestsCache.isEmpty ? store.records : closedRequestsCache
    }

    func exportClosedRequests() {
        do {
            let data = try XLSXArchiveExporter.makeClosedRequestsWorkbook(records: store.records)
            exportFileName = "LumaWork-requests-\(Self.exportDateFormatter.string(from: Date())).xlsx"
            exportDocument = XLSXExportDocument(data: data)
            isSpreadsheetExporterPresented = true
        } catch {
            store.errorMessage = appUserFacingErrorMessage(error)
        }
    }

    var warehouseRequestsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                AppSectionHeader(title: "Складская заявка", caption: "\(warehouseSearchRecords.count)")
                Spacer(minLength: 0)
                if isWarehouseSearchLoading {
                    ProgressView()
                        .tint(AppTheme.primaryTint)
                }
            }

            if !simpleOneStore.isAuthorized {
                AppEmptyState(
                    title: "Войдите в SimpleOne",
                    message: "Складские заявки ищутся напрямую в SimpleOne по ID терминала.",
                    systemName: "person.crop.circle.badge.exclamationmark"
                )
            } else if warehouseTerminalIDQuery.isEmpty {
                AppEmptyState(
                    title: "Введите ID терминала",
                    message: "Складские заявки отображаются только по результатам поиска.",
                    systemName: "magnifyingglass"
                )
            } else if isWarehouseSearchLoading && warehouseSearchRecords.isEmpty {
                AppLoadingView(title: "Ищу складскую заявку по ID \(warehouseTerminalIDQuery)")
            } else if warehouseSearchError != nil {
                VStack(alignment: .leading, spacing: 12) {
                    AppEmptyState(
                        title: "Поиск не выполнен",
                        message: "Повторите поиск по ID терминала.",
                        systemName: "arrow.clockwise"
                    )

                    Button("Повторить") {
                        Task { await searchWarehouseRequestsIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            } else if warehouseSearchRecords.isEmpty {
                AppEmptyState(
                    title: "Складских заявок нет",
                    message: "По ID терминала \(warehouseTerminalIDQuery) SimpleOne ничего не вернул.",
                    systemName: "checklist"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(warehouseSearchRecords) { record in
                        simpleOneRequestCard(
                            record,
                            showsInformation: true,
                            showsDeadline: false,
                            showsAssignmentDetails: true,
                            usesSelectableText: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var warehouseSearchTaskID: String {
        "\(requestsMode.rawValue)|\(warehouseTerminalIDQuery)|\(simpleOneStore.isAuthorized)"
    }

    var warehouseTerminalIDQuery: String {
        normalizedWarehouseTerminalIDQuery(searchText)
    }

    func normalizedWarehouseTerminalIDQuery(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
    }

    func searchWarehouseRequestsIfNeeded() async {
        guard requestsMode == .warehouse else {
            isWarehouseSearchLoading = false
            return
        }

        let terminalID = warehouseTerminalIDQuery
        guard simpleOneStore.isAuthorized, !terminalID.isEmpty else {
            warehouseSearchRecords = []
            warehouseSearchError = nil
            isWarehouseSearchLoading = false
            return
        }

        isWarehouseSearchLoading = true
        warehouseSearchError = nil
        defer {
            if warehouseTerminalIDQuery == terminalID {
                isWarehouseSearchLoading = false
            }
        }
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let records = try await simpleOneStore.fetchRequests(terminalID: terminalID)
            guard !Task.isCancelled, warehouseTerminalIDQuery == terminalID else { return }
            warehouseSearchRecords = uniqueSimpleOneRecords(records)
            warehouseSearchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, warehouseTerminalIDQuery == terminalID else { return }
            warehouseSearchRecords = []
            let message: String
            switch AppErrorPresentation.classification(for: error) {
            case .cancellation:
                return
            case .network(let kind):
                message = kind.message
            case .domain:
                message = appUserFacingErrorMessage(error, showsNetworkBanner: false)
                    ?? "Не удалось выполнить поиск складских заявок."
            }
            warehouseSearchError = message
            AppBannerCenter.shared.show(message, style: .error)
        }
    }

    func simpleOneRequestsContent(
        emptyTitle: String,
        emptyMessage: String,
        records: [ActiveRequestListItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if simpleOneStore.isLoading && records.isEmpty {
                AppLoadingView(title: "Получаю список заявок SimpleOne")
            } else if records.isEmpty {
                AppEmptyState(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemName: "checklist"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, item in
                        simpleOneRequestCard(item)
                            .depthStackPrimary(
                                reduceMotion: reduceMotion,
                                stage: index
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
