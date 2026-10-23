import Foundation

nonisolated struct GsmProfileImport: Codable, Hashable, Sendable {
    let profile: GsmProfile
    let sources: [String: String]
    let notes: [String]
}

/// Reads data and cached values only. Never evaluates workbook expressions or external links.
nonisolated enum GsmProfileXlsx {
    static let maximumFileBytes = 30 * 1024 * 1024

    static func previousMonth(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func read(_ url: URL, expectedMonth: String, projects: [GsmProjectOption]) throws -> GsmProfileImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        return try parse(data, expectedMonth: expectedMonth, projects: projects)
    }

    static func parse(_ data: Data, expectedMonth: String, projects: [GsmProjectOption]) throws -> GsmProfileImport {
        guard data.count <= maximumFileBytes else { throw failure("Размер XLSX превышает 30 МиБ.") }
        let book = try Workbook(data)
        let pl = try book.sheet("ПЛ-ТК")
        let sz = try book.sheet("СЗ-ТК")
        let fuel = try book.sheet("Отчет по ТК")
        let catalog = book.values("Список проектов")
        guard pl["B5", default: ""].contains("ФИО сотрудника"),
              pl["Q8", default: ""].contains("конец периода"), fuel["A4"] == "Вид топлива" else {
            throw failure("Не распознан шаблон отчёта ГСМ.")
        }
        func required(_ sheet: String, _ ref: String) throws -> String {
            let value = book.value(sheet, ref)
            guard !value.isEmpty else { throw failure("В \(sheet)!\(ref) нет значения. Пересчитайте и сохраните XLSX в Excel.") }
            return value
        }
        let months = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
        let monthName = try required("ПЛ-ТК", "M3").lowercased()
        let rawYear = Double(try required("ПЛ-ТК", "Q3")) ?? 0
        guard let monthIndex = months.firstIndex(of: monthName), rawYear.isFinite,
              rawYear >= 2000, rawYear <= 2100, rawYear.rounded() == rawYear else {
            throw failure("Не удалось определить месяц отчёта.")
        }
        let month = monthIndex + 1
        let year = Int(rawYear)
        let sourceMonth = String(format: "%04d-%02d", year, month)
        guard sourceMonth == expectedMonth else {
            throw failure("Выберите отчёт за \(expectedMonth). В файле указан \(sourceMonth).")
        }
        let end = Double(try required("ПЛ-ТК", "AE8").replacingOccurrences(of: ",", with: ".")) ?? -1
        guard end.isFinite, end >= 0, end <= Double(Int32.max), end.rounded() == end else {
            throw failure("ПЛ-ТК!AE8 (R8C31): некорректный конечный одометр.")
        }
        let norm = Double(try required("Отчет по ТК", "C3").replacingOccurrences(of: ",", with: ".")) ?? 0
        guard norm.isFinite, norm > 0 else { throw failure("Не удалось прочитать норму топлива из Отчет по ТК!C3.") }
        var sources: [String: String] = [:]
        var notes = ["В отчёте нет остатка топлива. Остаток не вычисляется и не принимается за ноль. История маршрутов и заправок не импортируется."]
        func field(_ key: String, _ sheet: String, _ ref: String) -> String {
            let value = book.value(sheet, ref)
            if !value.isEmpty { sources[key] = "\(sheet)!\(ref)" }
            else { notes.append("Поле \(key) отсутствует в \(sheet)!\(ref) — заполните вручную.") }
            return value
        }
        func row(_ cells: [String: String], column: String, predicate: (String) -> Bool) -> Int? {
            let matches = cells.filter { rowNumber($0.key, column: column) != nil && predicate($0.value) }
            return matches.count == 1 ? matches.first.flatMap { rowNumber($0.key, column: column) } : nil
        }
        var profile = GsmProfile.empty
        profile.employeeFullName = field("employeeFullName", "Отчет по ТК", "A3")
        profile.employeeTitleCompany = field("employeeTitleCompany", "ПЛ-ТК", "E5")
        let prefix = profile.employeeFullName + ","
        if !profile.employeeFullName.isEmpty, profile.employeeTitleCompany.hasPrefix(prefix) {
            let parts = profile.employeeTitleCompany.dropFirst(prefix.count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                profile.employeeJobTitle = String(parts[0]).trimmed
                profile.employeeCompany = String(parts[1]).trimmed
            }
        }
        if profile.employeeJobTitle.isEmpty || profile.employeeCompany.isEmpty { notes.append("Проверьте должность и компанию: не удалось разделить ПЛ-ТК!E5.") }
        sources["employeeJobTitle"] = "ПЛ-ТК!E5 (после ФИО, до первой запятой)"
        sources["employeeCompany"] = "ПЛ-ТК!E5 (после должности)"
        profile.employeeAddressPhone = field("employeeAddressPhone", "ПЛ-ТК", "E6")
        let contact = profile.employeeAddressPhone
        let phonePattern = #"(?:\+?7|8)[\s(]*[0-9]{3}[\s)]*[0-9]{3}[-\s]*[0-9]{2}[-\s]*[0-9]{2}\s*$"#
        if let range = contact.range(of: phonePattern, options: .regularExpression) {
            profile.employeePhone = GsmPhoneFormatter.format(String(contact[range]))
            profile.employeeAddress = String(contact[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ",; "))
        } else {
            profile.employeeAddress = contact
            notes.append("Телефон не распознан — заполните вручную.")
        }
        sources["employeeAddress"] = "ПЛ-ТК!E6 (до телефона)"
        sources["employeePhone"] = "ПЛ-ТК!E6 (телефон в конце строки)"
        if let row = row(sz, column: "C", predicate: { $0 == "Сотрудник" }) {
            profile.employeeShortName = field("employeeShortName", "СЗ-ТК", "Q\(row)")
        }
        if let row = row(fuel, column: "A", predicate: { $0.hasPrefix("ФИО ") }) {
            profile.employeeReportSignName = String(field("employeeReportSignName", "Отчет по ТК", "A\(row)").dropFirst(4)).trimmed
        }
        if let row = row(pl, column: "C", predicate: { $0.contains("ФИО уполномоченного сотрудника") }) {
            profile.authorizedFullName = field("authorizedFullName", "ПЛ-ТК", "C\(row - 1)")
            let parts = profile.authorizedFullName.split(whereSeparator: \.isWhitespace)
            if parts.count == 3 {
                profile.authorizedShortName = "\(parts[0]) \(parts[1].prefix(1)). \(parts[2].prefix(1))."
                sources["authorizedShortName"] = "ПЛ-ТК!C\(row - 1) (фамилия и инициалы)"
            }
        }
        let total = fuel.compactMap { $0.value == "Итого по:" ? rowNumber($0.key, column: "A") : nil }.min()
        let fuelCells = fuel.compactMap { ref, value -> (Int, String)? in
            guard let row = rowNumber(ref, column: "A"), row >= 5, row < (total ?? 5), !value.isEmpty else { return nil }
            return (row, value)
        }.sorted { $0.0 < $1.0 }
        profile.fuelTypes = fuelCells.map(\.1).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        profile.fuelType = profile.fuelTypes.first ?? ""
        sources["fuelTypes"] = "Отчет по ТК!" + fuelCells.map { "A\($0.0)" }.joined(separator: ",")
        sources["fuelType"] = sources["fuelTypes"]
        profile.fuelNorm = norm
        profile.defaultStartOdometer = Int(end)
        profile.reportStartMonth = String(format: "%04d-%02d", month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1)
        sources["fuelNorm"] = "Отчет по ТК!C3"
        sources["defaultStartOdometer"] = "ПЛ-ТК!AE8"
        sources["reportStartMonth"] = "ПЛ-ТК!M3,Q3 + 1 месяц"
        profile.driverLicenseNumber = field("driverLicenseNumber", "ПЛ-ТК", "AC5")
        profile.fuelCardNumber = field("fuelCardNumber", "ПЛ-ТК", "AC6")
        profile.carModel = field("carModel", "ПЛ-ТК", "J7")
        profile.licensePlate = field("licensePlate", "ПЛ-ТК", "AE7")
        func project(_ kind: String) -> GsmProjectOption? {
            let budgetCells = pl.filter { ref, _ in
                guard let row = rowNumber(ref, column: "D") else { return false }
                let value = pl["AJ\(row)", default: ""].uppercased()
                return value == kind || (kind == "ARM" && value == "АРМ")
            }
            let budgets = Set(budgetCells.values.filter { !$0.isEmpty })
            var candidates = budgets.count == 1 ? projects.filter { $0.budgetCode == budgets.first } : []
            var catalogSource = ""
            if candidates.count > 1, let budget = budgets.first,
               let catalogRow = row(catalog, column: "B", predicate: { $0 == budget }) {
                candidates = candidates.filter { $0.name == catalog["A\(catalogRow)"] }
                catalogSource = "; Список проектов!A\(catalogRow),B\(catalogRow)"
            }
            guard candidates.count == 1, let found = candidates.first else {
                if kind == "POS" || !budgets.isEmpty { notes.append("Выберите проект \(kind) вручную: однозначное соответствие справочнику не найдено.") }
                return nil
            }
            let source = "ПЛ-ТК!" + budgetCells.keys.sorted().joined(separator: ",") + " (AJ=\(kind))\(catalogSource) → справочник"
            sources[kind == "POS" ? "posProjectId" : "armProjectId"] = source
            if kind == "POS" { sources["budgetCode"] = source; sources["projectName"] = source }
            return found
        }
        let pos = project("POS")
        profile.posProjectID = pos?.id
        profile.budgetCode = pos?.budgetCode ?? ""
        profile.projectName = pos?.name ?? ""
        profile.armProjectID = project("ARM")?.id
        for (key, value) in [("employeeShortName", profile.employeeShortName), ("employeeReportSignName", profile.employeeReportSignName), ("authorizedFullName", profile.authorizedFullName), ("authorizedShortName", profile.authorizedShortName), ("fuelTypes", profile.fuelType)] where value.isEmpty {
            notes.append("Поле \(key) не определено однозначно — заполните вручную.")
        }
        return GsmProfileImport(profile: profile, sources: sources, notes: notes)
    }

    private static func rowNumber(_ ref: String, column: String) -> Int? {
        guard ref.hasPrefix(column) else { return nil }
        let tail = ref.dropFirst(column.count)
        guard !tail.isEmpty, tail.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(tail)
    }

    private struct Cell { let value: String; let formula: String }

    private final class Workbook {
        var cells: [String: [String: Cell]] = [:]

        init(_ data: Data) throws {
            let archive = try ZIPArchive(data: data, maximumEntries: 512, maximumPartBytes: 16 * 1024 * 1024, maximumTotalBytes: 48 * 1024 * 1024)
            func part(_ path: String) throws -> Data { try archive.extract(path) }
            var names: [String: String] = [:]
            let relationshipURI = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            try XML.read(part("xl/workbook.xml"), start: { tag, attrs in
                if tag == "sheet", let name = attrs["name"]?.trimmed, let id = attrs[relationshipURI + "|id"] {
                    guard names[name] == nil else { throw failure("Неоднозначные имена листов XLSX.") }
                    names[name] = id
                }
            })
            var relations: [String: String] = [:]
            try XML.read(part("xl/_rels/workbook.xml.rels"), start: { tag, attrs in
                if tag == "Relationship", attrs["TargetMode"] != "External", let id = attrs["Id"], let target = attrs["Target"], !target.contains(".."), !target.contains(":") {
                    guard relations[id] == nil else { throw failure("Неоднозначные связи XLSX.") }
                    relations[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                }
            })
            var shared: [String] = []
            if archive.entries["xl/sharedStrings.xml"] != nil {
                var item = "", inText = false
                try XML.read(part("xl/sharedStrings.xml"), start: { tag, _ in
                    if tag == "si" { item = "" }; if tag == "t" { inText = true }
                }, text: { if inText { item += $0 } }, end: { tag in
                    if tag == "t" { inText = false }; if tag == "si" { shared.append(item) }
                })
            }
            for name in ["ПЛ-ТК", "СЗ-ТК", "Отчет по ТК", "Список проектов"] {
                guard let id = names[name], let path = relations[id] else { continue }
                var sheet: [String: Cell] = [:]
                var ref = "", type = "", capture = "", value = "", formula = ""
                try XML.read(part(path), start: { tag, attrs in
                    if tag == "c" { ref = attrs["r"] ?? ""; type = attrs["t"] ?? ""; value = ""; formula = "" }
                    if ["v", "t", "f"].contains(tag) { capture = tag }
                }, text: { text in
                    if capture == "f" { formula += text } else if capture == "v" || capture == "t" { value += text }
                }, end: { tag in
                    if ["v", "t", "f"].contains(tag) { capture = "" }
                    if tag == "c" {
                        guard !ref.isEmpty, sheet[ref] == nil else { throw failure("Неоднозначная ячейка XLSX: \(ref).") }
                        let resolved: String
                        if type == "s" { resolved = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "" }
                        else { resolved = type == "e" ? "" : value }
                        sheet[ref] = Cell(value: resolved.trimmed, formula: formula)
                    }
                })
                cells[name] = sheet
            }
        }

        func sheet(_ name: String) throws -> [String: String] {
            guard cells[name] != nil else { throw failure("Нет листа «\(name)».") }
            return values(name)
        }
        func values(_ name: String) -> [String: String] { cells[name, default: [:]].keys.reduce(into: [:]) { $0[$1] = value(name, $1) } }
        func value(_ sheet: String, _ ref: String, depth: Int = 0) -> String {
            guard let cell = cells[sheet]?[ref] else { return "" }
            if !cell.value.isEmpty { return cell.value }
            guard depth < 8, !cell.formula.isEmpty else { return "" }
            let pattern = #"^(?:(?:'([^']+)'|([^!]+))!)?\$?([A-Z]+)\$?([0-9]+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: cell.formula, range: NSRange(cell.formula.startIndex..., in: cell.formula)) else { return "" }
            func group(_ index: Int) -> String { Range(match.range(at: index), in: cell.formula).map { String(cell.formula[$0]) } ?? "" }
            let target = (group(1).isEmpty ? group(2) : group(1)).trimmed
            return value(target.isEmpty ? sheet : target, group(3) + group(4), depth: depth + 1)
        }
    }

    private final class XML: NSObject, XMLParserDelegate {
        var start: (String, [String: String]) throws -> Void = { _, _ in }
        var text: (String) -> Void = { _ in }
        var end: (String) throws -> Void = { _ in }
        var namespaces: [String: String] = [:]
        var error: Error?
        var depth = 0

        static func read(_ data: Data, start: @escaping (String, [String: String]) throws -> Void, text: @escaping (String) -> Void = { _ in }, end: @escaping (String) throws -> Void = { _ in }) throws {
            let xmlText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian) ?? ""
            guard !xmlText.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !xmlText.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!ENTITY") else {
                throw failure("Внешние XML-сущности и DTD не поддерживаются.")
            }
            let delegate = XML()
            delegate.start = start; delegate.text = text; delegate.end = end
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            let success = parser.parse()
            if let error = delegate.error { throw error }
            guard success else { throw failure("Не удалось прочитать XML отчёта ГСМ.") }
        }
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix] = namespaceURI }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { namespaces.removeValue(forKey: prefix) }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            do {
                guard depth <= 128 else { throw failure("Слишком сложная структура XML.") }
                var attrs = attributes
                for (key, value) in attributes {
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uri = namespaces[String(parts[0])] { attrs[uri + "|" + parts[1]] = value }
                }
                try start(elementName, attrs)
            } catch { self.error = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            do { try end(elementName) } catch { self.error = error; parser.abortParsing() }
            depth -= 1
        }
        private func rejectEntities(_ parser: XMLParser) { error = failure("Внешние XML-сущности и DTD не поддерживаются."); parser.abortParsing() }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejectEntities(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejectEntities(parser) }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { rejectEntities(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { rejectEntities(parser); return nil }
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "GsmProfileXlsx", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

nonisolated private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


extension GsmProfile {
    /// Fill only requested blank account fields. The caller persists them on explicit Save.
    @MainActor func fillingUserProfile(_ current: UserProfileData) -> UserProfileData {
        let names = employeeFullName.split(whereSeparator: \.isWhitespace).map(String.init)
        let word = #"^[\p{L}]+(?:[-'’][\p{L}]+)*$"#
        let fullName = names.count == 3 && names.allSatisfy {
            $0.count >= 2 && $0.range(of: word, options: .regularExpression) != nil
        } ? names : []
        let cityPattern = #"^(?:г\.\s*|г\s+|город\s+)([\p{L}]+(?:[ -][\p{L}]+)*)$"#
        let cityRegex = try? NSRegularExpression(pattern: cityPattern, options: .caseInsensitive)
        let cities = employeeAddress.components(separatedBy: CharacterSet(charactersIn: ",;")).compactMap { segment -> String? in
            let value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = cityRegex?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
        func fill(_ existing: String?, _ imported: String?) -> String? {
            UserProfileData.clean(existing) != nil ? existing : UserProfileData.clean(imported) ?? existing
        }
        var result = current
        result.lastName = fill(current.lastName, fullName.first)
        result.firstName = fill(current.firstName, fullName.count == 3 ? fullName[1] : nil)
        result.middleName = fill(current.middleName, fullName.count == 3 ? fullName[2] : nil)
        result.jobTitle = fill(current.jobTitle, employeeJobTitle)
        result.city = fill(current.city, cities.count == 1 ? cities[0] : nil)
        return result
    }
}
