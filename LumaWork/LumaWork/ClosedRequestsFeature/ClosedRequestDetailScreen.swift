import Foundation
import SwiftUI

struct ClosedRequestDetailScreen: View {
    let record: ClosedRequestRecord

    var body: some View {
        AppScreen(bottomContentPadding: 0) {
            AppCard {
                AppSectionHeader(title: record.requestNumber, caption: statusText)

                if !record.shortDescription.isEmpty {
                    AppSelectableText(text: record.shortDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AppStatRow(title: "Статус", value: statusText)
                AppStatRow(title: "Тип заявки", value: nilIfEmpty(localizedRequestType(record.requestType)))
                let timeText = closedRequestTimeText(for: record)
                AppStatRow(title: timeText.title, value: nilIfEmpty(timeText.value))
                if !closureCodeText.isEmpty {
                    AppStatRow(title: "Код закрытия", value: closureCodeText)
                }
                if !sbpIDText.isEmpty {
                    AppStatRow(title: "ID СБП", value: sbpIDText)
                }
                AppStatRow(title: "Исполнитель", value: nilIfEmpty(record.engineerName))

                HStack(alignment: .top, spacing: 10) {
                    Text("ID терминала")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                    Spacer(minLength: 12)
                    if record.terminalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AppSelectableText(
                            text: "Информация отсутствует",
                            textStyle: .subheadline,
                            textAlignment: .right
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        AppSelectableText(
                            text: record.terminalID,
                            textStyle: .subheadline,
                            textAlignment: .right
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("Номер заявки")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.mutedTint)
                    Spacer(minLength: 12)
                    if record.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AppSelectableText(
                            text: "Информация отсутствует",
                            textStyle: .subheadline,
                            textAlignment: .right
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        AppSelectableText(
                            text: record.incomingNumber,
                            textStyle: .subheadline,
                            textAlignment: .right
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            if !record.customer.isEmpty || !contactPerson.isEmpty || !record.address.isEmpty || !record.terminalModel.isEmpty || !merchantTINText.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Клиент и адрес")

                    if !record.customer.isEmpty {
                        AppStatRow(title: "Заказчик", value: record.customer)
                    }
                    if !contactPerson.isEmpty {
                        AppStatRow(title: "Контактное лицо", value: contactPerson)
                    }
                    if !record.address.isEmpty {
                        AppStatRow(title: "Адрес", value: normalizedAddress(record.address))
                    }
                    if !merchantTINText.isEmpty {
                        AppStatRow(title: "ИНН ТСП", value: merchantTINText)
                    }
                    if !record.terminalModel.isEmpty {
                        AppStatRow(title: "Модель POS", value: record.terminalModel)
                    }
                    if !record.engineerShift.isEmpty {
                        AppStatRow(title: "Смена инженера", value: record.engineerShift)
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

            if !resolutionText.isEmpty {
                LongTextCard(title: "Решение", text: resolutionText)
            }

            if !equipmentInfoFields.isEmpty {
                AppCard {
                    AppSectionHeader(title: "Оборудование")
                    ForEach(equipmentInfoFields, id: \.title) { field in
                        AppStatRow(title: field.title, value: field.value)
                    }
                }
            }

            if !closedInformationText.isEmpty {
                LongTextCard(title: "Информация", text: closedInformationText)
            }

            if !additionalInformation.isEmpty {
                LongTextCard(title: "Доп. информация", text: additionalInformation)
            }

            if !descriptionText.isEmpty {
                LongTextCard(title: "Описание", text: descriptionText)
            }
        }
        .navigationTitle("Заявка")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
    }

    private func nilIfEmpty(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Информация отсутствует" : trimmed
    }

    private var statusText: String {
        if isReturnEquipment(record.requestType) {
            return localizedClosedRequestStatus(record.status)
        }
        return record.completionStatus.title
    }

    private func closedRequestTimeText(for record: ClosedRequestRecord) -> (title: String, value: String) {
        if isReturnEquipment(record.requestType) {
            let registeredAt = record.registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ("Время регистрации", registeredAt.isEmpty ? record.closedAt : registeredAt)
        }
        return ("Выполнена", record.closedAt)
    }

    private func isReturnEquipment(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    private var contactPerson: String {
        record.contactPerson?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var terminalID: String {
        record.terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sbpIDText: String {
        firstNonEmpty([
            infoValue(for: ["ID СБП"]),
            extractedLabeledValue(from: [additionalInformation, descriptionText, record.rawInfo], labels: ["ID СБП"])
        ])
    }

    private var merchantTINText: String {
        firstNonEmpty([
            record.merchantTIN,
            infoValue(for: ["ИНН ТСП"]),
            extractedLabeledValue(from: [additionalInformation, descriptionText, record.rawInfo], labels: ["ИНН ТСП"])
        ])
    }

    private var closureCodeText: String {
        firstNonEmpty([
            record.closureCode,
            infoValue(for: ["Код закрытия"]),
            extractedLabeledValue(from: [additionalInformation, descriptionText, record.rawInfo], labels: ["Код закрытия"])
        ])
    }

    private var resolutionText: String {
        firstNonEmpty([
            record.resolution,
            infoValue(for: ["Решение"]),
            extractedLabeledValue(from: [additionalInformation, descriptionText, record.rawInfo], labels: ["Решение"])
        ])
    }

    private var closedInformationText: String {
        let rawInfo = record.rawInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawInfo.isEmpty {
            return rawInfo
        }

        return visibleInfoFields
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleInfoFields: [ClosedRequestInfoField] {
        record.infoFields.filter { !isDedicatedInfoKey($0.key) }
    }

    private var equipmentInfoFields: [(title: String, value: String)] {
        [
            equipmentInfoField(
                title: "Серийный номер установленного ФН",
                aliases: ["Cерийный номер установленного ФН"],
                primaryValue: record.installedFiscalStorageSerialNumber
            ),
            equipmentInfoField(
                title: "Использованный код активации тарифа ОФД",
                aliases: [],
                primaryValue: record.ofdTariffActivationCode
            ),
            equipmentInfoField(
                title: "Использованная SIM карта",
                aliases: [],
                primaryValue: record.usedSIMCard
            )
        ]
        .compactMap { $0 }
    }

    private var additionalInformation: String {
        infoValue(for: ["Доп. информация", "Доп информация", "Дополнительная информация"])
    }

    private var descriptionText: String {
        infoValue(for: ["Описание"])
    }

    private func infoValue(for keys: Set<String>) -> String {
        let normalizedKeys = Set(keys.map(normalizedInfoKey))
        return record.infoFields
            .first { normalizedKeys.contains(normalizedInfoKey($0.key)) }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func equipmentInfoField(
        title: String,
        aliases: [String],
        primaryValue: String?
    ) -> (title: String, value: String)? {
        let labels = [title] + aliases
        let value = firstNonEmpty([
            primaryValue,
            infoValue(for: Set(labels)),
            extractedLabeledValue(
                from: [additionalInformation, descriptionText, record.rawInfo],
                labels: labels
            )
        ])

        guard !value.isEmpty else { return nil }
        return (title: title, value: value)
    }

    private func isLongTextInfoKey(_ key: String) -> Bool {
        let normalizedKey = normalizedInfoKey(key)
        return normalizedKey == "доп. информация"
            || normalizedKey == "доп информация"
            || normalizedKey == "дополнительная информация"
            || normalizedKey == "описание"
            || normalizedKey == "решение"
    }

    private func isDedicatedInfoKey(_ key: String) -> Bool {
        isLongTextInfoKey(key) || isEquipmentInfoKey(key) || normalizedInfoKey(key) == "код закрытия"
    }

    private func isEquipmentInfoKey(_ key: String) -> Bool {
        let normalizedKey = normalizedInfoKey(key)
        return normalizedKey == "серийный номер установленного фн"
            || normalizedKey == "cерийный номер установленного фн"
            || normalizedKey == "использованный код активации тарифа офд"
            || normalizedKey == "использованная sim карта"
    }

    private func normalizedInfoKey(_ key: String) -> String {
        key
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private func localizedRequestType(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
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
            return raw
        }
    }

    private func normalizedAddress(_ raw: String) -> String {
        raw.normalizedAddressStartingFromAlushta()
    }
}
