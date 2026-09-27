import Foundation

nonisolated enum XLSXRequestsParser {
    nonisolated static func parse(data: Data, fileName: String) throws -> ClosedRequestsSnapshot {
        let archive = try ZIPArchive(data: data)
        let worksheetPath = archive.entries.keys
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted()
            .first

        guard let worksheetPath else {
            throw ClosedRequestsImportError.worksheetNotFound
        }

        let sharedStrings: [String]
        if archive.entries["xl/sharedStrings.xml"] != nil {
            sharedStrings = try SharedStringsXMLParser.parse(data: archive.extract("xl/sharedStrings.xml"))
        } else {
            sharedStrings = []
        }

        let rows = try WorksheetXMLParser.parse(
            data: archive.extract(worksheetPath),
            sharedStrings: sharedStrings
        )

        // Preserve worksheet order through merge so duplicate request numbers
        // deterministically use the last row from the imported file. The store
        // sorts the final deduplicated snapshot once before committing it.
        let records = rows.compactMap(record(fromExportRow:))

        return ClosedRequestsSnapshot(
            fileName: fileName,
            importedAt: Date(),
            records: records
        )
    }

    nonisolated static func record(fromExportRow row: [String: String]) -> ClosedRequestRecord? {
        guard let record = makeRecord(from: row),
              isReturnEquipment(record.requestType) || isIncludedStatus(record.status) else {
            return nil
        }
        return record
    }

    nonisolated private static func makeRecord(from row: [String: String]) -> ClosedRequestRecord? {
        let requestNumber = value(for: "Номер заявки", in: row)
        guard !requestNumber.isEmpty else { return nil }

        let rawInfo = value(for: "Информация", in: row)
        let infoFields = parseInfoFields(rawInfo)
        let closedAt = importValue(
            for: ["Выполнена", "Время Выполнена", "Время \"Выполнена\"", "Дата закрытия в МК", "Дата закрытия МК", "Дата закрытия"],
            in: row,
            infoFields: infoFields
        )
        let registeredAt = importValue(
            for: ["Время регистрации", "Дата регистрации", "Зарегистрирована"],
            in: row,
            infoFields: infoFields
        )
        let status = value(for: "Статус", in: row)
        let importedIncomingNumber = incomingNumber(in: row, infoFields: infoFields)

        return ClosedRequestRecord(
            requestNumber: requestNumber,
            shortDescription: value(for: "Краткое описание", in: row),
            status: status.isEmpty ? "Закрыта" : status,
            engineerShift: value(for: "Смена инженера", in: row),
            workgroup: value(for: "Рабочая группа", in: row),
            requestType: value(for: "Тип заявки", in: row),
            address: importValue(for: ["Адрес установки терминала", "Адрес ТСП", "Адрес"], in: row, infoFields: infoFields),
            customer: importValue(for: ["Заказчик", "Наименование юр.лица", "Наименование юр. лица", "Клиент"], in: row, infoFields: infoFields),
            contactPerson: importValue(for: ["Контактное лицо", "Kонтактное лицо"], in: row, infoFields: infoFields),
            engineerName: value(for: "Исполнитель.Имя Фамилия", in: row),
            terminalModel: value(for: "Модель POS-терминала", in: row),
            merchantTIN: ClosedRequestsMerchantTINSupport.resolvedTIN(
                directTIN: importValue(for: "ИНН ТСП", in: row, infoFields: infoFields),
                information: rawInfo
            ),
            posEquipment: importValue(for: "Оборудование POS", in: row, infoFields: infoFields),
            dismantledEquipmentSerialNumber: importValue(
                for: "Серийный номер демонтируемого ТО",
                in: row,
                infoFields: infoFields
            ),
            engineerComment: value(for: "Комментарий инженера", in: row),
            closedAt: normalizedClosedAt(closedAt),
            registeredAt: normalizedClosedAt(registeredAt),
            closureCode: importValue(
                for: ["Код закрытия", "Код закрытия МК", "Код закрытия заявки", "Код решения", "Результат закрытия"],
                in: row,
                infoFields: infoFields
            ),
            resolution: importValue(for: "Решение", in: row, infoFields: infoFields),
            terminalID: importValue(for: ["ID терминал", "ID терминала", "Оборудование POS"], in: row, infoFields: infoFields),
            incomingNumber: importedIncomingNumber.isEmpty ? requestNumber : importedIncomingNumber,
            infoFields: infoFields,
            rawInfo: rawInfo,
            installedFiscalStorageSerialNumber: importValue(
                for: ["Серийный номер установленного ФН", "Cерийный номер установленного ФН"],
                in: row,
                infoFields: infoFields
            ),
            ofdTariffActivationCode: importValue(
                for: "Использованный код активации тарифа ОФД",
                in: row,
                infoFields: infoFields
            ),
            usedSIMCard: importValue(
                for: "Использованная SIM карта",
                in: row,
                infoFields: infoFields
            )
        )
    }

    nonisolated private static func value(for key: String, in row: [String: String]) -> String {
        if let value = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return value
        }

        let normalizedKey = normalizedHeader(key)
        return row.first { normalizedHeader($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func importValue(
        for key: String,
        in row: [String: String],
        infoFields: [ClosedRequestInfoField]
    ) -> String {
        importValue(for: [key], in: row, infoFields: infoFields)
    }

    nonisolated private static func importValue(
        for keys: [String],
        in row: [String: String],
        infoFields: [ClosedRequestInfoField]
    ) -> String {
        for key in keys {
            let columnValue = value(for: key, in: row)
            if !columnValue.isEmpty {
                return columnValue
            }
        }

        for key in keys {
            let infoValue = value(for: key, in: infoFields)
            if !infoValue.isEmpty {
                return infoValue
            }
        }

        return ""
    }

    nonisolated private static func value(for key: String, in infoFields: [ClosedRequestInfoField]) -> String {
        let normalizedKey = normalizedInfoKey(key)
        return infoFields
            .first { normalizedInfoKey($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func incomingNumber(
        in row: [String: String],
        infoFields: [ClosedRequestInfoField]
    ) -> String {
        let directValue = value(for: "Входящий номер", in: row)
        if !directValue.isEmpty {
            return directValue
        }

        for key in ["Входящий номер", "Номер заявки Мультикарты", "Номер заявки Мультикарта", "Номер заявки"] {
            let infoValue = value(for: key, in: infoFields)
            if !infoValue.isEmpty {
                return infoValue
            }
        }

        return ""
    }

    nonisolated private static func normalizedInfoKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func normalizedHeader(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func isIncludedStatus(_ raw: String) -> Bool {
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !status.isEmpty else { return false }

        return status == "completed"
            || status == "closed"
            || status == "resolved"
            || status.contains("выполн")
            || status.contains("закрыт")
            || status.contains("решен")
            || status.contains("решён")
            || status.contains("отказ")
            || status.contains("отклон")
    }

    nonisolated private static func isReturnEquipment(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    nonisolated private static func parseInfoFields(_ rawInfo: String) -> [ClosedRequestInfoField] {
        rawInfo
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> ClosedRequestInfoField? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }

                if let separator = line.firstIndex(of: ":") {
                    let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return nil }
                    return ClosedRequestInfoField(key: key, value: value)
                }

                return ClosedRequestInfoField(key: line, value: "")
            }
    }

    nonisolated private static func normalizedClosedAt(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let date = parseClosedAt(trimmed) {
            return normalizedClosedAtFormatter.string(from: date)
        }

        return trimmed
    }

    nonisolated private static func parseClosedAt(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed) {
            let excelBaseDate = Date(timeIntervalSince1970: -2209161600) // 1899-12-30
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }

        for formatter in closedAtFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    nonisolated private static let closedAtFormatters: [DateFormatter] = {
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

    nonisolated private static let normalizedClosedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}

nonisolated final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentText = ""
    private var isInsideStringItem = false
    private var isInsideTextNode = false

    static func parse(data: Data) throws -> [String] {
        let delegate = SharedStringsXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ClosedRequestsImportError.xml("Не удалось прочитать текстовые данные XLSX.")
        }
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "si":
            isInsideStringItem = true
            currentText = ""
        case "t":
            if isInsideStringItem {
                isInsideTextNode = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextNode {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "t":
            isInsideTextNode = false
        case "si":
            strings.append(currentText)
            isInsideStringItem = false
        default:
            break
        }
    }
}

nonisolated final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var headers = [Int: String]()
    private var rows = [[String: String]]()

    private var currentRowIndex = 0
    private var currentRow = [String: String]()
    private var currentCellReference = ""
    private var currentCellType = ""
    private var currentValue = ""
    private var isReadingValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(data: Data, sharedStrings: [String]) throws -> [[String: String]] {
        let delegate = WorksheetXMLParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ClosedRequestsImportError.xml("Не удалось прочитать лист XLSX.")
        }
        return delegate.rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRowIndex = Int(attributeDict["r"] ?? "") ?? 0
            currentRow = [:]
        case "c":
            currentCellReference = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
        case "v", "t":
            isReadingValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingValue {
            currentValue += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v", "t":
            isReadingValue = false
        case "c":
            commitCurrentCell()
        case "row":
            if currentRowIndex > 1, !currentRow.isEmpty {
                rows.append(currentRow)
            }
        default:
            break
        }
    }

    private func commitCurrentCell() {
        let columnIndex = columnIndex(from: currentCellReference)
        let resolvedValue = resolveCellValue(currentValue, type: currentCellType)

        if currentRowIndex == 1 {
            headers[columnIndex] = resolvedValue
        } else if let header = headers[columnIndex], !header.isEmpty {
            currentRow[header] = resolvedValue
        }

        currentCellReference = ""
        currentCellType = ""
        currentValue = ""
    }

    private func resolveCellValue(_ rawValue: String, type: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == "s", let index = Int(trimmed), sharedStrings.indices.contains(index) else {
            return trimmed
        }
        return sharedStrings[index]
    }

    private func columnIndex(from reference: String) -> Int {
        let letters = reference.prefix { $0.isLetter }
        return letters.reduce(0) { partialResult, character in
            let value = Int(character.uppercased().unicodeScalars.first?.value ?? 65) - 64
            return partialResult * 26 + value
        }
    }
}
