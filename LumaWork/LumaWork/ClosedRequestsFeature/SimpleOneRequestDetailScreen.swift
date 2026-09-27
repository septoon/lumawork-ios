import Foundation
import SwiftUI

struct SimpleOneRequestDetailScreen: View {
    let record: SimpleOneRequestRecord
    let lumaWorkAuthToken: String?
    let onOpenWarehouseRequests: ((String) -> Void)?

    @State private var companyLookupSelection: CompanyLookupSelection?

    init(
        record: SimpleOneRequestRecord,
        lumaWorkAuthToken: String? = nil,
        onOpenWarehouseRequests: ((String) -> Void)? = nil
    ) {
        self.record = record
        self.lumaWorkAuthToken = lumaWorkAuthToken
        self.onOpenWarehouseRequests = onOpenWarehouseRequests
    }

    var body: some View {
        if isWarehouseRequest(record) {
            AppScreen(bottomContentPadding: 0) {
                LongTextCard(title: "Информация", text: nilIfEmpty(warehouseInformationBlock(record)))
            }
            .navigationTitle("Заявка")
            .navigationBarTitleDisplayMode(.inline)
            .appSidebarBackButton()
            .sheet(item: $companyLookupSelection) { selection in
                CompanyLookupSheet(selection: selection, authToken: lumaWorkAuthToken)
            }
        } else {
            AppScreen(bottomContentPadding: 0) {
            AppCard {
                AppSectionHeader(title: record.number, caption: record.state)

                if !record.shortDescription.isEmpty {
                    AppSelectableText(text: record.shortDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if record.source == .active {
                    AppStatRow(title: "Тип заявки", value: nilIfEmpty(requestTypeText))
                    if !waitingReasonText.isEmpty {
                        AppStatRow(title: "Причина ожидания", value: waitingReasonText)
                    }
                    if !sutsDeadlineText.isEmpty {
                        AppStatRow(title: "Предельный срок", value: nilIfEmpty(formatDate(sutsDeadlineText)))
                    }
                    if !sbpIDText.isEmpty {
                        AppStatRow(title: "ID СБП", value: sbpIDText)
                    }
                    if !initiatorText.isEmpty {
                        AppStatRow(title: "Инициатор", value: initiatorText)
                    }
                    if !priorityText.isEmpty {
                        AppStatRow(title: "Приоритет", value: priorityText)
                    }
                } else {
                    AppStatRow(title: "Входящий номер", value: nilIfEmpty(incomingNumberText))
                    AppStatRow(title: "Тип заявки", value: nilIfEmpty(requestTypeText))
                    AppStatRow(title: "Выполнена", value: nilIfEmpty(formatDate(primaryDateText)))
                    AppStatRow(title: "Исполнитель", value: nilIfEmpty(record.assignedUser))
                    AppStatRow(title: "Рабочая группа", value: nilIfEmpty(record.assignmentGroup))
                }

                detailTextRow(
                    title: "ID терминала",
                    value: terminalIDText,
                    isLinkLike: !terminalIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onTap: { AppClipboard.copyTerminalID(terminalIDText) },
                    onLongPress: terminalIDLongPressAction
                )
                detailTextRow(title: "Номер заявки", value: incomingNumberText)
            }

            if !clientServiceParentText.isEmpty || !clientServiceText.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Сервис")
                    if !clientServiceParentText.isEmpty {
                        AppStatRow(title: "Клиентский сервис (Родитель)", value: clientServiceParentText)
                    }
                    if !clientServiceText.isEmpty {
                        AppStatRow(title: "Клиентский сервис", value: clientServiceText)
                    }
                }
            }

            if !customerText.isEmpty || !contactPersonText.isEmpty || !addressText.isEmpty || !terminalModelText.isEmpty || !merchantTINText.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Клиент и адрес")
                    if !customerText.isEmpty {
                        AppStatRow(title: "Заказчик", value: customerText)
                    }
                    if !contactPersonText.isEmpty {
                        AppStatRow(title: "Контактное лицо", value: contactPersonText)
                    }
                    if !addressText.isEmpty {
                        AppStatRow(title: "Адрес", value: normalizedAddress(addressText))
                    }
                    if !merchantTINText.isEmpty {
                        detailTextRow(
                            title: "ИНН ТСП",
                            value: merchantTINText,
                            isLinkLike: true,
                            onTap: { openCompanyLookup(for: merchantTINText) },
                            onLongPress: { AppClipboard.copy(merchantTINText, message: "ИНН скопирован") },
                            accessibilityHint: "Коснитесь, чтобы открыть данные организации. Удерживайте, чтобы скопировать ИНН."
                        )
                    }
                    if !terminalModelText.isEmpty {
                        AppStatRow(title: "Модель POS", value: terminalModelText)
                    }
                }
            }

            if !equipmentInfoFields.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Оборудование")
                    ForEach(equipmentInfoFields, id: \.title) { field in
                        AppStatRow(title: field.title, value: field.value)
                    }
                }
            }

            if !record.engineerComment.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Комментарий инженера")
                    AppSelectableText(text: record.engineerComment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if record.source == .active {
                AppCard {
                    AppSectionHeader(title: "Основная информация")
                    ForEach(Array(activeShortTableFields.enumerated()), id: \.offset) { indexedField in
                        ActiveTableFieldBlock(field: indexedField.element)
                    }
                }
            }

            if (record.source == .active || isWarehouseRequest(record)), !informationText.isEmpty {
                LongTextCard(title: "Информация", text: informationText)
            } else if record.source != .active, !visibleInfoFields.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Информация")
                    ForEach(Array(visibleInfoFields.enumerated()), id: \.offset) { indexedField in
                        InfoFieldBlock(field: indexedField.element)
                    }
                }
            } else if record.source != .active, !unparsedInformationText.isEmpty {
                LongTextCard(title: "Информация", text: unparsedInformationText)
            }

            if !additionalInformationText.isEmpty {
                LongTextCard(title: "Доп. информация", text: additionalInformationText)
            }

            if !descriptionText.isEmpty {
                if record.source != .active {
                    LongTextCard(title: "Описание", text: descriptionText)
                }
            }
        }
        .navigationTitle("Заявка")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .sheet(item: $companyLookupSelection) { selection in
            CompanyLookupSheet(selection: selection, authToken: lumaWorkAuthToken)
        }
        }
    }

    private func nilIfEmpty(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Информация отсутствует" : trimmed
    }

    @ViewBuilder
    private func detailTextRow(
        title: String,
        value: String,
        isLinkLike: Bool = false,
        onTap: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil,
        accessibilityHint: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
            Spacer(minLength: 12)
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppSelectableText(
                    text: "Информация отсутствует",
                    textStyle: .subheadline,
                    textAlignment: .right
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AppSelectableText(
                    text: value,
                    textStyle: .subheadline,
                    weight: isLinkLike ? .semibold : .regular,
                    color: isLinkLike ? AppTheme.primaryTint : AppTheme.ink,
                    textAlignment: .right,
                    isUnderlined: isLinkLike,
                    onTap: onTap,
                    onLongPress: onLongPress
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHint(
                    accessibilityHint ?? (onLongPress == nil
                        ? (onTap == nil ? "" : "Коснитесь, чтобы скопировать.")
                        : "Коснитесь, чтобы скопировать. Удерживайте, чтобы открыть складские заявки.")
                )
            }
        }
    }

    private var terminalIDLongPressAction: (() -> Void)? {
        let terminalID = terminalIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let onOpenWarehouseRequests, !terminalID.isEmpty else { return nil }
        return { onOpenWarehouseRequests(terminalID) }
    }

    private func openCompanyLookup(for inn: String) {
        guard let selection = CompanyLookupSelection(inn: inn) else {
            AppBannerCenter.shared.show("Некорректный ИНН", style: .error)
            return
        }
        AppHaptics.trigger()
        companyLookupSelection = selection
    }

    private var incomingNumberText: String {
        firstMeaningful([
            record.incomingNumber,
            infoFieldValue(labels: ["Номер заявки Мультикарты", "Номер заявки"]),
            record.shortDescription.hasPrefix("SUTS") ? record.shortDescription : nil
        ])
    }

    private var registeredAtText: String {
        record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var waitingReasonText: String {
        record.waitingReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var initiatorText: String {
        record.initiator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var priorityText: String {
        record.priority?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var clientServiceParentText: String {
        record.clientServiceParent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var clientServiceText: String {
        record.clientService?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var requestTypeText: String {
        localizedRequestType(firstMeaningful([
            record.requestType,
            infoFieldValue(labels: ["Тип заявки", "Тип работ", "Вид заявки", "Тип обращения"])
        ]))
    }

    private var primaryDateText: String {
        firstMeaningful([
            record.primaryDate,
            infoFieldValue(labels: [
                "Дедлайн",
                "Срок выполнения",
                "Плановая дата",
                "Согласованная дата и время проведения работ",
                "Согласованная дата и время предоставления доступа"
            ])
        ])
    }

    private var sutsDeadlineText: String {
        firstMeaningful([
            infoFieldValue(labels: ["Предельный срок СУТС", "Предельный срок"]),
            record.deadline
        ])
    }

    private var sbpIDText: String {
        firstMeaningful([
            infoFieldValue(labels: ["ID СБП"]),
            extractedLabeledValue(from: [informationText, additionalInformationText, descriptionText, record.informationText], labels: ["ID СБП"])
        ])
    }

    private var customerText: String {
        firstMeaningful([
            record.customer,
            infoFieldValue(labels: ["Наименование юр.лица", "Наименование юр. лица", "Заказчик", "Клиент"])
        ])
    }

    private var contactPersonText: String {
        firstMeaningful([
            record.contactPerson,
            infoFieldValue(labels: ["Контактное лицо", "ФИО контактного лица"])
        ])
    }

    private var addressText: String {
        firstMeaningful([
            record.address,
            infoFieldValue(labels: ["Адрес ТСП", "Адрес установки терминала", "Адрес"])
        ])
    }

    private var terminalIDText: String {
        firstMeaningful([
            record.terminalID,
            infoFieldValue(labels: ["ID терминала", "ID терминал"])
        ])
    }

    private var terminalModelText: String {
        firstMeaningful([
            record.terminalModel,
            infoFieldValue(labels: ["Модель POS-терминала", "Модель POS", "Модель терминала"])
        ])
    }

    private var merchantTINText: String {
        firstMeaningful([
            infoFieldValue(labels: ["ИНН ТСП"]),
            extractedLabeledValue(from: [informationText, additionalInformationText, descriptionText, record.informationText], labels: ["ИНН ТСП"])
        ])
    }

    private var informationFields: [ClosedRequestInfoField] {
        let rawInformation = record.additionalInformation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields = parseInformationFields(rawInformation)
        if !fields.isEmpty {
            return fields
        }
        return parseInformationFields(record.description)
    }

    private var activeTableFields: [ClosedRequestInfoField] {
        if let tableFields = record.tableFields, !tableFields.isEmpty {
            return resolvedActiveTableFields(tableFields)
        }

        return [
            ClosedRequestInfoField(key: "Номер заявки", value: record.number),
            ClosedRequestInfoField(key: "Краткое описание", value: record.shortDescription),
            ClosedRequestInfoField(key: "Статус", value: record.state),
            ClosedRequestInfoField(key: "Тип заявки", value: record.requestType),
            ClosedRequestInfoField(key: "Адрес установки терминала", value: addressText),
            ClosedRequestInfoField(key: "Заказчик", value: customerText),
            ClosedRequestInfoField(key: "ID СБП", value: sbpIDText),
            ClosedRequestInfoField(key: "ИНН ТСП", value: merchantTINText),
            ClosedRequestInfoField(key: "Модель POS-терминала", value: terminalModelText),
            ClosedRequestInfoField(key: "Информация", value: record.additionalInformation ?? ""),
            ClosedRequestInfoField(key: "ID терминал", value: terminalIDText),
            ClosedRequestInfoField(key: "Комментарий инженера", value: record.engineerComment),
            ClosedRequestInfoField(key: "Доп. информация", value: additionalInformationText),
            ClosedRequestInfoField(key: "Исполнитель", value: record.assignedUser),
            ClosedRequestInfoField(key: "Kонтактное лицо", value: contactPersonText),
            ClosedRequestInfoField(key: "Предельный срок СУТС", value: sutsDeadlineText),
            ClosedRequestInfoField(key: "Оборудование POS", value: infoFieldValue(labels: ["Оборудование POS"])),
            ClosedRequestInfoField(key: "Номер принятого оборудования POS", value: infoFieldValue(labels: ["Номер принятого оборудования POS"])),
            ClosedRequestInfoField(key: "Оборудование Pin Pad", value: infoFieldValue(labels: ["Оборудование Pin Pad"])),
            ClosedRequestInfoField(key: "Номер принятого оборудования PIN", value: infoFieldValue(labels: ["Номер принятого оборудования PIN"]))
        ]
    }

    private func resolvedActiveTableFields(_ fields: [ClosedRequestInfoField]) -> [ClosedRequestInfoField] {
        var resolvedFields = fields.map(resolvedActiveTableField)
        let normalizedKeys = Set(resolvedFields.map { normalizedEquipmentLabel($0.key) })

        if !normalizedKeys.contains("id сбп"), !sbpIDText.isEmpty {
            resolvedFields.append(ClosedRequestInfoField(key: "ID СБП", value: sbpIDText))
        }
        if !normalizedKeys.contains("инн тсп"), !merchantTINText.isEmpty {
            resolvedFields.append(ClosedRequestInfoField(key: "ИНН ТСП", value: merchantTINText))
        }

        return resolvedFields
    }

    private func resolvedActiveTableField(_ field: ClosedRequestInfoField) -> ClosedRequestInfoField {
        let normalizedKey = normalizedEquipmentLabel(field.key)
        let fallbackValue: String
        switch normalizedKey {
        case "id сбп":
            fallbackValue = sbpIDText
        case "инн тсп":
            fallbackValue = merchantTINText
        default:
            fallbackValue = ""
        }

        guard !fallbackValue.isEmpty else {
            return field
        }

        return ClosedRequestInfoField(
            key: field.key,
            value: firstMeaningful([field.value, fallbackValue])
        )
    }

    private var activeShortTableFields: [ClosedRequestInfoField] {
        activeTableFields.filter { field in
            let normalizedKey = normalizedEquipmentLabel(field.key)
            return normalizedKey != "информация" && normalizedKey != "доп. информация"
        }
    }

    private var informationText: String {
        let fromTable = record.tableFields?
            .first { normalizedEquipmentLabel($0.key) == "информация" }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromTable.isEmpty {
            return fromTable
        }
        return record.additionalInformation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var visibleInfoFields: [ClosedRequestInfoField] {
        informationFields.filter { !isDedicatedInfoKey($0.key) }
    }

    private var equipmentInfoFields: [(title: String, value: String)] {
        [
            infoField(title: "Принадлежность оборудования", labels: ["Принадлежность оборудования по заявке"]),
            infoField(title: "Серийный номер демонтируемого ТО", labels: ["Серийный номер демонтируемого ТО"]),
            infoField(title: "Серийный номер демонтируемого PIN", labels: ["Серийный номер демонтируемого PIN"]),
            infoField(title: "Производитель устанавливаемого ТО", labels: ["Производитель устанавливаемого ТО"]),
            infoField(title: "Модель устанавливаемого ТО", labels: ["Модель устанавливаемого ТО"]),
            infoField(title: "Тип устанавливаемого ТО", labels: ["Тип устанавливаемого ТО"]),
            infoField(title: "Оборудование POS", labels: ["Оборудование POS"]),
            infoField(title: "Оборудование Pin Pad", labels: ["Оборудование Pin Pad"])
        ]
        .compactMap { $0 }
    }

    private var additionalInformationText: String {
        let fromTable = record.tableFields?
            .first { normalizedEquipmentLabel($0.key) == "доп. информация" }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromTable.isEmpty {
            return fromTable
        }
        return infoFieldValue(labels: ["Доп. информация", "Доп информация", "Дополнительная информация"])
    }

    private var descriptionText: String {
        record.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var unparsedInformationText: String {
        let rawInformation = record.additionalInformation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return informationFields.isEmpty ? rawInformation : ""
    }

    private func infoField(title: String, labels: [String]) -> (title: String, value: String)? {
        let value = meaningful(infoFieldValue(labels: labels))
        guard !value.isEmpty else { return nil }
        return (title: title, value: value)
    }

    private func infoFieldValue(labels: [String]) -> String {
        let normalizedLabels = labels.map(normalizedEquipmentLabel)
        return allInformationFields.first { field in
            let normalizedKey = normalizedEquipmentLabel(field.key)
            return normalizedLabels.contains(normalizedKey)
        }?
        .value
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var allInformationFields: [ClosedRequestInfoField] {
        var fields = informationFields

        fields.append(contentsOf: record.tableFields ?? [])

        let tableInformation = record.tableFields?
            .first { normalizedEquipmentLabel($0.key) == "информация" }?
            .value ?? ""
        fields.append(contentsOf: parseInformationFields(tableInformation))

        let tableAdditionalInformation = record.tableFields?
            .first { normalizedEquipmentLabel($0.key) == "доп. информация" }?
            .value ?? ""
        fields.append(contentsOf: parseInformationFields(tableAdditionalInformation))

        fields.append(contentsOf: parseInformationFields(record.description))
        return fields
    }

    private func parseInformationFields(_ text: String) -> [ClosedRequestInfoField] {
        normalizedMulticardInformationText(text)
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> ClosedRequestInfoField? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                guard let separatorIndex = line.firstIndex(of: ":") else {
                    return ClosedRequestInfoField(key: line, value: "")
                }

                let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let valueStart = line.index(after: separatorIndex)
                let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return ClosedRequestInfoField(key: key, value: value)
            }
    }

    private func firstMeaningful(_ values: [String?]) -> String {
        values
            .compactMap { meaningful($0 ?? "") }
            .first { !$0.isEmpty } ?? ""
    }

    private func meaningful(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedEquipmentLabel(trimmed) == "информация отсутствует" ? "" : trimmed
    }

    private func isDedicatedInfoKey(_ key: String) -> Bool {
        let normalizedKey = normalizedEquipmentLabel(key)
        return [
            "номер заявки мультикарты",
            "номер заявки",
            "тип заявки",
            "тип работ",
            "вид заявки",
            "тип обращения",
            "дедлайн",
            "срок выполнения",
            "плановая дата",
            "согласованная дата и время проведения работ",
            "согласованная дата и время предоставления доступа",
            "наименование юр.лица",
            "наименование юр. лица",
            "заказчик",
            "клиент",
            "контактное лицо",
            "фио контактного лица",
            "адрес тсп",
            "адрес установки терминала",
            "адрес",
            "id терминала",
            "id терминал",
            "модель pos-терминала",
            "модель pos",
            "модель терминала",
            "доп. информация",
            "доп информация",
            "дополнительная информация",
            "описание"
        ].contains(normalizedKey) || isEquipmentInfoKey(normalizedKey)
    }

    private func isEquipmentInfoKey(_ normalizedKey: String) -> Bool {
        [
            "принадлежность оборудования по заявке",
            "серийный номер демонтируемого то",
            "серийный номер демонтируемого pin",
            "производитель устанавливаемого то",
            "модель устанавливаемого то",
            "тип устанавливаемого то",
            "оборудование pos",
            "оборудование pin pad",
            "id сбп",
            "инн тсп"
        ].contains(normalizedKey)
    }

    private func formatDate(_ raw: String) -> String {
        guard let date = parseDate(raw) else {
            return raw
        }
        return Self.dateFormatter.string(from: date)
    }

    private func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in Self.dateParsingFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func localizedRequestType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        switch firstToken {
        case "install":
            return "Установка"
        case "dismounting":
            return "Демонтаж"
        case "returnEquip":
            return "Возврат ТО"
        case "serviceStd":
            return "Сервисная"
        case "replacement":
            return "Замена"
        default:
            return trimmed
        }
    }

    private func normalizedAddress(_ raw: String) -> String {
        raw.normalizedAddressStartingFromAlushta()
    }

    private static let dateParsingFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
