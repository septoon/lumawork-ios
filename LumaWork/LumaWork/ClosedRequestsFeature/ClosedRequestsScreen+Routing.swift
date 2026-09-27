import Foundation
import SwiftUI

extension ClosedRequestsScreen {
    @ViewBuilder
    func requestDetailDestination(for route: RequestDetailRoute) -> some View {
        switch route {
        case .closed(let record):
            let detailRecord = simpleOneDetailRecord(from: record)
            ActiveSimpleOneRequestDetailScreen(
                record: detailRecord,
                lumaWorkAuthToken: sessionStore.authToken,
                personalComment: personalComment(for: detailRecord),
                onEditPersonalComment: { comment in
                    openClientCommentEditor(record: detailRecord, existingComment: comment)
                },
                onOpenWarehouseRequests: openWarehouseRequests(for:)
            )
        case .simpleOne(let record):
            if record.source == .active {
                ActiveSimpleOneRequestDetailScreen(
                    record: record,
                    simpleOneAuthKey: simpleOneStore.browserAuthKey,
                    lumaWorkAuthToken: sessionStore.authToken,
                    personalComment: personalComment(for: record),
                    onEditPersonalComment: { comment in
                        openClientCommentEditor(record: record, existingComment: comment)
                    },
                    onOpenWarehouseRequests: openWarehouseRequests(for:)
                )
            } else {
                SimpleOneRequestDetailScreen(
                    record: record,
                    lumaWorkAuthToken: sessionStore.authToken,
                    onOpenWarehouseRequests: openWarehouseRequests(for:)
                )
            }
        case .closedSimpleOne(let record):
            ActiveSimpleOneRequestDetailScreen(
                record: record,
                lumaWorkAuthToken: sessionStore.authToken,
                personalComment: personalComment(for: record),
                onEditPersonalComment: { comment in
                    openClientCommentEditor(record: record, existingComment: comment)
                },
                onOpenWarehouseRequests: openWarehouseRequests(for:)
            )
        }
    }

    func personalComment(for record: SimpleOneRequestRecord) -> ClientPersonalComment? {
        guard shouldShowClientComment(for: record) else { return nil }
        return clientCommentsStore.comment(
            forTIN: clientCommentTIN(for: record),
            address: simpleOneAddressText(record)
        )
    }

    func openClientCommentEditor(record: SimpleOneRequestRecord, existingComment: ClientPersonalComment? = nil) {
        guard shouldShowClientComment(for: record) else { return }
        openClientCommentEditor(
            tin: clientCommentTIN(for: record),
            existingComment: existingComment,
            currentTarget: clientCommentTarget(for: record)
        )
    }

    func openClientCommentEditor(
        tin rawTIN: String,
        existingComment: ClientPersonalComment? = nil,
        currentTarget: ClientPersonalCommentTarget? = nil
    ) {
        let normalizedTIN = ClientPersonalCommentsStore.normalizedTIN(rawTIN)
        clientCommentTargetOptions = clientCommentTargets(forTIN: rawTIN, including: currentTarget)
        if let cachedDraft = ClientPersonalCommentDraftStore.load(),
           !normalizedTIN.isEmpty,
           cachedDraft.normalizedTIN == normalizedTIN {
            clientCommentDraft = cachedDraft
            return
        }

        if let existingComment {
            clientCommentDraft = ClientPersonalCommentDraft(comment: existingComment, fallbackTIN: rawTIN)
            return
        }

        var draft = ClientPersonalCommentDraft()
        draft.tin = rawTIN.filter(\.isNumber)
        if let currentTarget {
            draft.targets = [currentTarget]
        }
        clientCommentDraft = draft
    }

    func clientCommentActionButton(
        tin rawTIN: String,
        existingComment: ClientPersonalComment?,
        currentTarget: ClientPersonalCommentTarget? = nil
    ) -> some View {
        Button {
            AppHaptics.trigger()
            openClientCommentEditor(
                tin: rawTIN,
                existingComment: existingComment,
                currentTarget: currentTarget
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: existingComment == nil ? "text.bubble" : "pencil")
                    .font(.caption.weight(.semibold))
                Text(existingComment == nil ? "Добавить личный комментарий" : "Редактировать комментарий")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(AppTheme.primaryTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.primaryTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.primaryTint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(ClientPersonalCommentsStore.normalizedTIN(rawTIN).isEmpty && existingComment == nil)
    }

    func shouldShowClientComment(for record: SimpleOneRequestRecord) -> Bool {
        shouldShowClientComment(forRequestType: simpleOneRequestTypeText(record))
    }

    func shouldShowClientComment(forRequestType requestType: String) -> Bool {
        !isReturnEquipment(requestType)
    }

    func clientCommentTargets(
        forTIN rawTIN: String,
        including currentTarget: ClientPersonalCommentTarget?
    ) -> [ClientPersonalCommentTarget] {
        let normalizedTIN = ClientPersonalCommentsStore.normalizedTIN(rawTIN)
        guard !normalizedTIN.isEmpty else {
            return currentTarget.map { [$0] } ?? []
        }

        var targetsByKey: [String: ClientPersonalCommentTarget] = [:]
        func append(_ target: ClientPersonalCommentTarget?) {
            guard let target else { return }
            targetsByKey[target.normalizedKey] = target
        }

        append(currentTarget)

        for record in simpleOneStore.activeRequests + simpleOneStore.closedRequests + closedSimpleOneStore.records + warehouseSearchRecords {
            guard shouldShowClientComment(for: record) else { continue }
            guard ClientPersonalCommentsStore.normalizedTIN(simpleOneMerchantTINText(record)) == normalizedTIN else { continue }
            append(clientCommentTarget(for: record))
        }

        for record in closedRequests {
            guard shouldShowClientComment(forRequestType: record.requestType) else { continue }
            let recordTIN = firstNonEmpty([
                record.merchantTIN,
                searchInfoValue(for: "ИНН ТСП", in: record)
            ])
            guard ClientPersonalCommentsStore.normalizedTIN(recordTIN) == normalizedTIN else { continue }
            append(clientCommentTarget(address: record.address))
        }

        return targetsByKey.values.sorted { lhs, rhs in
            lhs.displayText.localizedCaseInsensitiveCompare(rhs.displayText) == .orderedAscending
        }
    }

    func clientCommentTIN(for record: SimpleOneRequestRecord) -> String {
        clientCommentTIN(
            directTIN: simpleOneMerchantTINText(record),
            terminalID: simpleOneTerminalIDText(record),
            requestType: simpleOneRequestTypeText(record)
        )
    }

    func clientCommentTIN(
        directTIN rawTIN: String,
        terminalID rawTerminalID: String,
        requestType _: String = ""
    ) -> String {
        let directTIN = ClosedRequestsMerchantTINSupport.normalizedValidTIN(rawTIN)
        if !directTIN.isEmpty {
            return directTIN
        }
        let normalizedTerminalID = normalizedClientCommentTerminalID(rawTerminalID)
        if let resolvedTIN = clientCommentTINByTerminalID[normalizedTerminalID],
           !ClosedRequestsMerchantTINSupport.normalizedValidTIN(resolvedTIN).isEmpty {
            return ClosedRequestsMerchantTINSupport.normalizedValidTIN(resolvedTIN)
        }
        return ""
    }

    func isDismountingRequest(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "dismounting"
            || type.contains("демонтаж")
    }

    func normalizedClientCommentTerminalID(_ raw: String) -> String {
        ClientPersonalCommentsStore.normalizedScopeText(raw)
    }

    func clientCommentTarget(for record: SimpleOneRequestRecord) -> ClientPersonalCommentTarget? {
        clientCommentTarget(
            address: simpleOneAddressText(record)
        )
    }

    func clientCommentTarget(address: String) -> ClientPersonalCommentTarget? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }
        return ClientPersonalCommentTarget(address: trimmedAddress)
    }

    func simpleOneDetailRecord(from record: ClosedRequestRecord) -> SimpleOneRequestRecord {
        let statusText = closedRequestStatusText(for: record)
        let tableFields = closedRequestDetailFields(from: record, statusText: statusText)
        return SimpleOneRequestRecord(
            source: .closed,
            sysID: record.requestNumber,
            number: record.requestNumber,
            incomingNumber: firstNonEmpty([record.incomingNumber, record.requestNumber]),
            registeredAt: record.registeredAt,
            state: statusText,
            stateRaw: record.rawStatus,
            shortDescription: record.shortDescription,
            assignmentGroup: record.workgroup,
            requestType: record.requestType,
            address: record.address,
            customer: record.customer,
            deadline: firstNonEmpty([record.registeredAt, record.closedAt]),
            resolvedAt: record.closedAt,
            completedAt: record.completedAt,
            closedAt: record.closedInMulticardAt,
            assignedUser: record.engineerName,
            terminalModel: record.terminalModel,
            terminalID: record.terminalID,
            contactPerson: record.contactPerson ?? "",
            contactPhone: record.contactPhone,
            engineerComment: record.engineerComment,
            closureCode: record.closureCode,
            resolution: record.resolution,
            additionalInformation: firstNonEmpty([record.additionalInformation, record.engineerComment]).isEmpty
                ? nil
                : firstNonEmpty([record.additionalInformation, record.engineerComment]),
            description: record.rawInfo,
            installedFiscalStorageSerialNumber: record.installedFiscalStorageSerialNumber,
            ofdTariffActivationCode: record.ofdTariffActivationCode,
            usedSIMCard: record.usedSIMCard,
            tableFields: tableFields
        )
    }

    func closedRequestDetailFields(from record: ClosedRequestRecord, statusText: String) -> [ClosedRequestInfoField] {
        var fields = record.infoFields
        appendDetailField("МК Статус", statusText, to: &fields)
        appendDetailField("Код статуса", record.rawStatus ?? "", to: &fields)
        appendDetailField("Время создания в МК", firstNonEmpty([record.registeredAt, record.closedAt]), to: &fields)
        appendDetailField("Тип заявки", record.requestType, to: &fields)
        appendDetailField("Заказчик", record.customer, to: &fields)
        appendDetailField("Kонтактное лицо", record.contactPerson ?? "", to: &fields)
        appendDetailField("Номер телефона ТСП", record.contactPhone ?? "", to: &fields)
        appendDetailField("Адрес установки терминала", record.address, to: &fields)
        appendDetailField("ИНН ТСП", record.merchantTIN ?? "", to: &fields)
        appendDetailField("ID терминал", record.terminalID, to: &fields)
        appendDetailField("Код закрытия", record.closureCode ?? "", to: &fields)
        appendDetailField("Решение", record.resolution ?? "", to: &fields)
        appendDetailField("Оборудование POS", record.posEquipment ?? "", to: &fields)
        appendDetailField("Серийный номер демонтируемого ТО", record.dismantledEquipmentSerialNumber ?? "", to: &fields)
        appendDetailField("Серийный номер установленного ФН", record.installedFiscalStorageSerialNumber ?? "", to: &fields)
        appendDetailField("Использованный код активации тарифа ОФД", record.ofdTariffActivationCode ?? "", to: &fields)
        appendDetailField("Использованная SIM карта", record.usedSIMCard ?? "", to: &fields)
        appendDetailField("Доп. информация", record.engineerComment, to: &fields)
        appendDetailField("Предельный срок СУТС", record.deadline ?? "", to: &fields)
        appendDetailField("Время выполнения", record.completedAt ?? "", to: &fields)
        appendDetailField("Дата закрытия в МК", record.closedInMulticardAt ?? "", to: &fields)
        appendDetailField("Доп. информация", record.additionalInformation ?? "", to: &fields)
        return fields
    }

    func appendDetailField(_ key: String, _ value: String, to fields: inout [ClosedRequestInfoField]) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return }
        let normalizedKey = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))
        if fields.contains(where: {
            $0.key
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU")) == normalizedKey
        }) {
            return
        }
        fields.append(ClosedRequestInfoField(key: key, value: trimmedValue))
    }
}
