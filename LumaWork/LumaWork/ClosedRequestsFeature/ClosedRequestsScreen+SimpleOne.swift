import Foundation
import SwiftUI

extension ClosedRequestsScreen {
    func rebuildActiveRequestItems() {
        var items = simpleOneStore.activeRequests.map { record in
            makeActiveRequestListItem(record)
        }
        var terminalTINIndex = clientCommentTINByTerminalID
        for item in items {
            let normalizedTerminalID = normalizedClientCommentTerminalID(item.terminalID)
            guard !normalizedTerminalID.isEmpty,
                  !ClosedRequestsMerchantTINSupport.normalizedValidTIN(item.merchantTIN).isEmpty else {
                continue
            }
            terminalTINIndex[normalizedTerminalID] = item.merchantTIN
        }
        for index in items.indices where ClosedRequestsMerchantTINSupport.normalizedValidTIN(items[index].merchantTIN).isEmpty {
            let normalizedTerminalID = normalizedClientCommentTerminalID(items[index].terminalID)
            if let resolvedTIN = terminalTINIndex[normalizedTerminalID],
               !ClosedRequestsMerchantTINSupport.normalizedValidTIN(resolvedTIN).isEmpty {
                items[index].merchantTIN = ClosedRequestsMerchantTINSupport.normalizedValidTIN(resolvedTIN)
            }
        }
        clientCommentTINByTerminalID = terminalTINIndex
        activeRequestItemsCache = items
        refreshFilteredActiveRequestItems()
    }

    func refreshFilteredActiveRequestItems() {
        let records = sortedActiveRequestItems(
            activeRequestItemsCache.filter { item in
                item.matchingStatusFilters.contains(activeStatusFilter)
            }
        )
        let query = normalizedSearchQuery
        guard !query.isEmpty else {
            filteredActiveRequestItemsCache = records
            return
        }
        filteredActiveRequestItemsCache = records.filter { $0.searchText.contains(query) }
    }

    func sortedActiveRequestItems(_ records: [ActiveRequestListItem]) -> [ActiveRequestListItem] {
        records.sorted { lhs, rhs in
            let leftDate = lhs.registeredSortDate ?? .distantPast
            let rightDate = rhs.registeredSortDate ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.record.number.localizedStandardCompare(rhs.record.number) == .orderedDescending
        }
    }

    func makeActiveRequestListItem(
        _ record: SimpleOneRequestRecord,
        includesInformation: Bool = false
    ) -> ActiveRequestListItem {
        let infoFields = simpleOneInfoFields(record)
        let incomingNumber: String = {
            let direct = record.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard direct.isEmpty else { return direct }
            return firstNonEmpty([
                extractedLabeledValue(
                    from: [record.informationText],
                    labels: ["Номер заявки Мультикарты", "Номер заявки"]
                ),
                record.shortDescription.hasPrefix("SUTS") ? record.shortDescription : nil
            ])
        }()
        let requestType: String = {
            let direct = record.requestType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard direct.isEmpty else { return localizedRequestType(direct) }
            return localizedRequestType(
                extractedLabeledValue(
                    from: [record.informationText],
                    labels: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"]
                )
            )
        }()
        let customer: String = {
            let direct = record.customer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard direct.isEmpty else { return direct }
            return simpleOneInfoValue(
                record,
                labels: ["Заказчик", "Наименование юр.лица", "Наименование юр. лица", "Клиент"],
                fields: infoFields
            )
        }()
        let address: String = {
            let direct = record.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard direct.isEmpty else { return direct }
            return simpleOneInfoValue(
                record,
                labels: ["Адрес установки терминала", "Адрес ТСП", "Адрес"],
                fields: infoFields
            )
        }()
        let terminalID: String = {
            let direct = record.terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard direct.isEmpty else { return direct }
            return simpleOneInfoValue(
                record,
                labels: [
                    "ID терминал",
                    "ID терминала",
                    "Оборудование POS",
                    "Оборудование POS-терминала",
                    "POS оборудование"
                ],
                fields: infoFields
            )
        }()
        let merchantTIN: String = {
            let direct = simpleOneInfoValue(
                record,
                labels: ["ИНН ТСП", "ИНН", "ИНН клиента"],
                fields: infoFields
            )
            guard direct.isEmpty else { return direct }
            return extractedLabeledValue(
                from: simpleOneInfoTexts(record),
                labels: ["ИНН ТСП", "ИНН", "ИНН клиента"]
            )
        }()
        let isStatusRefreshing = simpleOneStore.isRefreshingStatus(for: record)
        let statusText = isStatusRefreshing
            ? "Обновляю статус"
            : simpleOneMulticardStatusText(record, infoFields: infoFields)
        let registeredAt = record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deadline = record.deadline.trimmingCharacters(in: .whitespacesAndNewlines)

        return ActiveRequestListItem(
            record: record,
            incomingNumber: incomingNumber,
            requestType: requestType,
            customer: customer,
            address: address,
            terminalID: terminalID,
            merchantTIN: merchantTIN,
            information: includesInformation ? simpleOneInformationText(record) : "",
            statusText: statusText,
            isStatusRefreshing: isStatusRefreshing,
            registeredAtText: registeredAt.isEmpty ? nil : formatSimpleOneDate(registeredAt),
            deadlineText: deadline.isEmpty ? nil : formatSimpleOneDate(deadline),
            slaStatusText: record.slaStatusText,
            isOverdue: record.isOverdue,
            registeredSortDate: record.registeredDate,
            deadlineSortDate: record.deadlineDate,
            searchText: record.searchText,
            matchingStatusFilters: isStatusRefreshing
                ? Set(ActiveRequestsStatusFilter.allCases)
                : Set(ActiveRequestsStatusFilter.allCases.filter { $0.contains(status: statusText) })
        )
    }

    func simpleOneRequestCard(
        _ record: SimpleOneRequestRecord,
        showsInformation: Bool = false,
        showsDeadline: Bool = true,
        showsAssignmentDetails: Bool = false,
        usesSelectableText: Bool = false
    ) -> some View {
        simpleOneRequestCard(
            makeActiveRequestListItem(record, includesInformation: showsInformation),
            showsInformation: showsInformation,
            showsDeadline: showsDeadline,
            showsAssignmentDetails: showsAssignmentDetails,
            usesSelectableText: usesSelectableText
        )
    }

    func simpleOneRequestCard(
        _ item: ActiveRequestListItem,
        showsInformation: Bool = false,
        showsDeadline: Bool = true,
        showsAssignmentDetails: Bool = false,
        usesSelectableText: Bool = false
    ) -> some View {
        let record = item.record
        let currentTarget = clientCommentTarget(address: item.address)
        let showsClientComment = shouldShowClientComment(forRequestType: item.requestType)
        let personalComment = showsClientComment
            ? clientCommentsStore.comment(forTIN: item.merchantTIN, address: item.address)
            : nil
        let statusStyle = item.isStatusRefreshing
            ? SimpleOneMulticardStatusStyle.loading
            : SimpleOneMulticardStatusStyle.status(item.statusText)

        return SimpleOneActiveRequestCardContainer(
            statusText: item.statusText,
            statusStyle: statusStyle,
            isStatusRefreshing: item.isStatusRefreshing
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        simpleOneCardText(
                            item.incomingNumber.isEmpty ? record.number : item.incomingNumber,
                            textStyle: .headline,
                            weight: .semibold,
                            usesSelectableText: usesSelectableText
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !item.incomingNumber.isEmpty, item.incomingNumber != record.number {
                            simpleOneCardText(
                                record.number,
                                textStyle: .caption1,
                                weight: .medium,
                                color: AppTheme.mutedTint,
                                usesSelectableText: usesSelectableText
                            )
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 6) {
                        RequestChip(
                            text: item.requestType.isEmpty ? "Тип не указан" : item.requestType,
                            style: .requestType(item.requestType)
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if let registeredAtText = item.registeredAtText {
                    simpleOneCardInfoRow(title: "Зарегистрирована", value: registeredAtText, usesSelectableText: usesSelectableText)
                }
                if showsDeadline, let deadlineText = item.deadlineText {
                    simpleOneCardInfoRow(title: "Предельный срок", value: deadlineText, usesSelectableText: usesSelectableText)
                }
                if let slaStatusText = item.slaStatusText {
                    Text(slaStatusText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(item.isOverdue ? AppTheme.dangerTint : AppTheme.primaryTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            (item.isOverdue ? AppTheme.dangerTint : AppTheme.primaryTint).opacity(0.10),
                            in: Capsule()
                        )
                }
                if showsAssignmentDetails {
                    if !record.assignedUser.isEmpty {
                        simpleOneCardInfoRow(title: "Исполнитель", value: record.assignedUser, usesSelectableText: usesSelectableText)
                    }
                    if !record.assignmentGroup.isEmpty {
                        simpleOneCardInfoRow(title: "Группа", value: record.assignmentGroup, usesSelectableText: usesSelectableText)
                    }
                    if let priority = record.priority, !priority.isEmpty {
                        simpleOneCardInfoRow(title: "Приоритет", value: priority, usesSelectableText: usesSelectableText)
                    }
                }
                if let contactPhone = record.contactPhone, !contactPhone.isEmpty {
                    simpleOneCardInfoRow(title: "Телефон", value: contactPhone, usesSelectableText: usesSelectableText)
                }
                simpleOneCardInfoRow(title: "Заказчик", value: cardValue(item.customer), usesSelectableText: usesSelectableText)
                if !item.address.isEmpty {
                    simpleOneCardAddressRow(normalizedAddress(item.address), usesSelectableText: usesSelectableText)
                } else {
                    simpleOneCardInfoRow(title: "Адрес", value: cardValue(item.address), usesSelectableText: usesSelectableText)
                }
                simpleOneTerminalIDRow(item.terminalID, usesSelectableText: usesSelectableText)
                if showsClientComment {
                    if let personalComment {
                        ClientPersonalCommentBlock(comment: personalComment) {
                            openClientCommentEditor(
                                tin: item.merchantTIN,
                                existingComment: personalComment,
                                currentTarget: currentTarget
                            )
                        }
                    } else if !ClientPersonalCommentsStore.normalizedTIN(item.merchantTIN).isEmpty {
                        clientCommentActionButton(
                            tin: item.merchantTIN,
                            existingComment: nil,
                            currentTarget: currentTarget
                        )
                    }
                }
                if showsInformation {
                    simpleOneCardLongInfoBlock(
                        title: "Информация",
                        value: cardValue(item.information),
                        usesSelectableText: usesSelectableText
                    )
                }
            }
            .contentShape(Rectangle())
            .modifier(SimpleOneCardTapModifier(isEnabled: !usesSelectableText) {
                openSimpleOneRequest(record)
            })
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func openSimpleOneRequest(_ record: SimpleOneRequestRecord) {
        AppHaptics.trigger()

        guard record.source == .active else {
            selectedRequestRoute = .simpleOne(record)
            return
        }

        selectedRequestRoute = .simpleOne(record)
        Task {
            do {
                let detailedRecord = try await simpleOneStore.fetchDetailedRequest(record)
                if case .simpleOne(let selectedRecord) = selectedRequestRoute,
                   selectedRecord.id == detailedRecord.id {
                    selectedRequestRoute = .simpleOne(detailedRecord)
                }
            } catch is CancellationError {
                return
            } catch {
                simpleOneStore.errorMessage = appUserFacingErrorMessage(error)
            }
        }
    }

    @ViewBuilder
    func simpleOneCardText(
        _ text: String,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: Color = AppTheme.ink,
        textAlignment: NSTextAlignment = .natural,
        usesSelectableText: Bool
    ) -> some View {
        if usesSelectableText {
            AppSelectableText(
                text: text,
                textStyle: textStyle,
                weight: weight,
                color: color,
                textAlignment: textAlignment
            )
        } else {
            Text(text)
                .font(swiftUIFont(textStyle: textStyle, weight: weight))
                .foregroundStyle(color)
                .multilineTextAlignment(swiftUITextAlignment(textAlignment))
                .textSelection(.enabled)
        }
    }

    func simpleOneCardInfoRow(title: String, value: String, usesSelectableText: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            simpleOneCardText(
                value,
                textStyle: .subheadline,
                weight: .semibold,
                textAlignment: .right,
                usesSelectableText: usesSelectableText
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func simpleOneCardAddressRow(_ address: String, usesSelectableText: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Адрес")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            simpleOneCardText(
                address,
                textStyle: .subheadline,
                weight: .semibold,
                usesSelectableText: usesSelectableText
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func simpleOneTerminalIDRow(_ terminalID: String, usesSelectableText: Bool) -> some View {
        let trimmedTerminalID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ID терминала")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            if trimmedTerminalID.isEmpty {
                simpleOneCardText(
                    "Информация отсутствует",
                    textStyle: .subheadline,
                    textAlignment: .right,
                    usesSelectableText: usesSelectableText
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AppSelectableText(
                    text: trimmedTerminalID,
                    textStyle: .subheadline,
                    weight: .semibold,
                    color: AppTheme.primaryTint,
                    textAlignment: .right,
                    isUnderlined: true,
                    onTap: { AppClipboard.copyTerminalID(trimmedTerminalID) },
                    onLongPress: { openWarehouseRequests(for: trimmedTerminalID) }
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("ID терминала \(trimmedTerminalID)")
                .accessibilityHint("Коснитесь, чтобы скопировать. Удерживайте, чтобы открыть складские заявки.")
            }
        }
    }

    func openWarehouseRequests(for terminalID: String) {
        let trimmedTerminalID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminalID.isEmpty else { return }
        AppHaptics.trigger(.expandCollapse)
        warehouseTerminalSelection = WarehouseTerminalSelection(terminalID: trimmedTerminalID)
    }

    func simpleOneCardLongInfoBlock(title: String, value: String, usesSelectableText: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            simpleOneCardText(
                value,
                textStyle: .subheadline,
                usesSelectableText: usesSelectableText
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func swiftUIFont(textStyle: UIFont.TextStyle, weight: UIFont.Weight) -> Font {
        let font: Font
        switch textStyle {
        case .headline:
            font = .headline
        case .subheadline:
            font = .subheadline
        case .caption1, .caption2:
            font = .caption
        case .footnote:
            font = .footnote
        case .title1:
            font = .title
        case .title2:
            font = .title2
        case .title3:
            font = .title3
        default:
            font = .body
        }
        return font.weight(swiftUIFontWeight(weight))
    }

    func swiftUIFontWeight(_ weight: UIFont.Weight) -> Font.Weight {
        switch weight {
        case .black:
            return .black
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .light:
            return .light
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .thin:
            return .thin
        case .ultraLight:
            return .ultraLight
        default:
            return .regular
        }
    }

    func swiftUITextAlignment(_ alignment: NSTextAlignment) -> TextAlignment {
        switch alignment {
        case .center:
            return .center
        case .right:
            return .trailing
        default:
            return .leading
        }
    }

    func cardLongInfoBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func cardValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Информация отсутствует" : trimmed
    }

    func terminalIDRow(_ terminalID: String) -> some View {
        let trimmedTerminalID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ID терминала")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            if trimmedTerminalID.isEmpty {
                Text("Информация отсутствует")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AppSelectableText(
                    text: trimmedTerminalID,
                    textStyle: .subheadline,
                    weight: .semibold,
                    color: AppTheme.primaryTint,
                    textAlignment: .right,
                    isUnderlined: true,
                    onTap: { AppClipboard.copyTerminalID(trimmedTerminalID) },
                    onLongPress: { openWarehouseRequests(for: trimmedTerminalID) }
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("ID терминала \(trimmedTerminalID)")
                .accessibilityHint("Коснитесь, чтобы скопировать. Удерживайте, чтобы открыть складские заявки.")
            }
        }
    }

    func simpleOneIncomingNumberText(_ record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.incomingNumber,
            extractedLabeledValue(from: [record.informationText], labels: ["Номер заявки Мультикарты", "Номер заявки"]),
            record.shortDescription.hasPrefix("SUTS") ? record.shortDescription : nil
        ])
    }

    func simpleOneRequestTypeText(_ record: SimpleOneRequestRecord) -> String {
        let raw = firstNonEmpty([
            record.requestType,
            extractedLabeledValue(from: [record.informationText], labels: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"])
        ])
        return localizedRequestType(raw)
    }

    func simpleOneMulticardStatusText(_ record: SimpleOneRequestRecord) -> String {
        simpleOneMulticardStatusText(record, infoFields: simpleOneInfoFields(record))
    }

    func simpleOneMulticardStatusText(
        _ record: SimpleOneRequestRecord,
        infoFields: [ClosedRequestInfoField]
    ) -> String {
        let tableStatus = record.tableFields?
            .first {
                let key = normalizedEquipmentLabel($0.key)
                return key == normalizedEquipmentLabel("МК Статус")
                    || key == normalizedEquipmentLabel("Статус заявки Мультикарта")
            }?
            .value
        return displaySimpleOneMulticardStatus(firstNonEmpty([
            tableStatus,
            simpleOneInfoValue(record, labels: ["МК Статус", "МК статус", "Статус заявки Мультикарта"], fields: infoFields),
            "МК Статус не загружен"
        ]))
    }

    func displaySimpleOneMulticardStatus(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        switch normalized {
        case "storeequipissued":
            return "Оборудование выдано"
        default:
            return trimmed
        }
    }

    func simpleOneCustomerText(_ record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.customer,
            simpleOneInfoValue(record, labels: ["Заказчик", "Наименование юр.лица", "Наименование юр. лица", "Клиент"])
        ])
    }

    func simpleOneAddressText(_ record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.address,
            simpleOneInfoValue(record, labels: ["Адрес установки терминала", "Адрес ТСП", "Адрес"])
        ])
    }

    func simpleOneTerminalIDText(_ record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            record.terminalID,
            simpleOneInfoValue(record, labels: [
                "ID терминал",
                "ID терминала",
                "Оборудование POS",
                "Оборудование POS-терминала",
                "POS оборудование"
            ])
        ])
    }

    func simpleOneMerchantTINText(_ record: SimpleOneRequestRecord) -> String {
        firstNonEmpty([
            simpleOneInfoValue(record, labels: ["ИНН ТСП", "ИНН", "ИНН клиента"]),
            extractedLabeledValue(from: simpleOneInfoTexts(record), labels: ["ИНН ТСП", "ИНН", "ИНН клиента"])
        ])
    }

    func simpleOneInformationText(_ record: SimpleOneRequestRecord) -> String {
        if isWarehouseRequest(record) {
            return warehouseInformationBlock(record)
        }
        return simpleOnePrimaryInformationText(record)
    }

    func simpleOneInfoTexts(_ record: SimpleOneRequestRecord) -> [String] {
        [
            record.additionalInformation ?? "",
            record.description,
            record.informationText
        ] + (record.tableFields ?? []).map(\.value)
    }

    func simpleOneInfoValue(_ record: SimpleOneRequestRecord, labels: [String]) -> String {
        simpleOneInfoValue(record, labels: labels, fields: simpleOneInfoFields(record))
    }

    func simpleOneInfoValue(
        _ record: SimpleOneRequestRecord,
        labels: [String],
        fields: [ClosedRequestInfoField]
    ) -> String {
        let normalizedLabels = labels.map(normalizedEquipmentLabel)
        for field in fields {
            let normalizedKey = normalizedEquipmentLabel(field.key)
            guard normalizedLabels.contains(normalizedKey) else { continue }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, normalizedEquipmentLabel(value) != "информация отсутствует" {
                return value
            }
        }
        return ""
    }

    func simpleOneInfoFields(_ record: SimpleOneRequestRecord) -> [ClosedRequestInfoField] {
        (record.tableFields ?? []) + simpleOneInfoTexts(record)
            .flatMap { text in
                text
                    .split(whereSeparator: \.isNewline)
                    .compactMap { rawLine -> ClosedRequestInfoField? in
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { return nil }
                        guard let separator = line.firstIndex(of: ":") else {
                            return ClosedRequestInfoField(key: line, value: "")
                        }

                        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return nil }
                        return ClosedRequestInfoField(key: key, value: value)
                    }
            }
    }

    func simpleOnePrimaryInformationText(_ record: SimpleOneRequestRecord) -> String {
        let fromTable = record.tableFields?
            .first { normalizedEquipmentLabel($0.key) == "информация" }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromTable.isEmpty {
            return fromTable
        }
        return record.additionalInformation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct SimpleOneCardTapModifier: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}
