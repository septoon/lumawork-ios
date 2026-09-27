import Foundation
import SwiftUI

extension ClosedRequestsScreen {
    func requestCard(_ item: ClosedRequestListItem) -> some View {
        let hidesCustomerAddress = isReturnEquipment(item.record.requestType)
        let showsClientComment = shouldShowClientComment(forRequestType: item.record.requestType)
        let directMerchantTIN = firstNonEmpty([
            item.record.merchantTIN,
            searchInfoValue(for: "ИНН ТСП", in: item.record)
        ])
        let merchantTIN = clientCommentTIN(
            directTIN: directMerchantTIN,
            terminalID: item.record.terminalID,
            requestType: item.record.requestType
        )
        let currentTarget = clientCommentTarget(address: item.record.address)
        let personalComment = showsClientComment
            ? clientCommentsStore.comment(forTIN: merchantTIN, address: item.record.address)
            : nil

        return SimpleOneActiveRequestCardContainer(
            statusText: item.statusText,
            statusStyle: .closedStatus(item.statusText)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !item.record.incomingNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(item.record.incomingNumber)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        RequestChip(
                            text: item.requestType.isEmpty ? "Тип не указан" : item.requestType,
                            style: .requestType(item.requestType)
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                cardInfoRow(title: item.timeTitle, value: item.closedAtText)

                if !hidesCustomerAddress, !item.record.customer.isEmpty {
                    cardInfoRow(title: "Заказчик", value: item.record.customer)
                }
                if !hidesCustomerAddress, !item.record.address.isEmpty {
                    cardAddressRow(item.normalizedAddress)
                }
                if !item.record.terminalID.isEmpty {
                    terminalIDRow(item.record.terminalID)
                }
                if showsClientComment {
                    if let personalComment {
                        ClientPersonalCommentBlock(comment: personalComment) {
                            openClientCommentEditor(
                                tin: merchantTIN,
                                existingComment: personalComment,
                                currentTarget: currentTarget
                            )
                        }
                    } else if !ClientPersonalCommentsStore.normalizedTIN(merchantTIN).isEmpty {
                        clientCommentActionButton(
                            tin: merchantTIN,
                            existingComment: nil,
                            currentTarget: currentTarget
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                AppHaptics.trigger()
                selectedRequestRoute = .closed(item.record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func cardInfoRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func cardAddressRow(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Адрес")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(address)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func formatClosedAt(_ raw: String) -> String {
        guard let date = closedAtDate(raw) else {
            return raw
        }
        return Self.closedAtOutputFormatter.string(from: date)
    }

    func formatSimpleOneDate(_ raw: String) -> String {
        formatClosedAt(raw)
    }

    func formatImportedAt(_ date: Date) -> String {
        Self.importedAtFormatter.string(from: date)
    }

    func closedAtDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed) {
            let excelBaseDate = Date(timeIntervalSince1970: -2209161600) // 1899-12-30
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }

        for formatter in Self.closedAtParsingFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    func localizedRequestType(_ raw: String) -> String {
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

    func isReturnEquipment(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    static let closedAtParsingFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm",
            "MM.dd.yyyy HH:mm:ss",
            "MM.dd.yyyy HH:mm",
            "MM.dd.yyyy H:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy",
            "MM.dd.yyyy"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    static let closedAtOutputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static let dayCaptionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    static let searchDayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM"
        return formatter
    }()

    static let searchFullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    static let searchShortYearDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yy"
        return formatter
    }()

    static let searchSpacedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd MM yyyy"
        return formatter
    }()

    static let filterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM"
        return formatter
    }()

    static let importedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static let simpleOneUpdatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
