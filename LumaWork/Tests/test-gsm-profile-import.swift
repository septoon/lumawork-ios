import Foundation

@main
struct GsmProfileImportTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    static func fixture(month: String = "сентябрь", year: String = "2026", end: String = "123456", norm: String = "9.4", extra: String = "", prefix: String = "s:", cached: Bool = true) throws -> Data {
        func cell(_ ref: String, _ value: String) -> String {
            "<\(prefix)c r=\"\(ref)\" t=\"inlineStr\"><\(prefix)is><\(prefix)t>\(value)</\(prefix)t></\(prefix)is></\(prefix)c>"
        }
        func sheet(_ cells: String) -> Data { Data("<\(prefix)worksheet xmlns\(prefix.isEmpty ? "" : ":s")=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><\(prefix)sheetData><\(prefix)row>\(cells)</\(prefix)row></\(prefix)sheetData></\(prefix)worksheet>".utf8) }
        let pl = cell("B5", "ФИО сотрудника") + cell("Q8", "конец периода") + cell("M3", month) + cell("Q3", year)
            + cell("E5", "Тестов Тест Тестович, Инженер, ООО Тест, филиал") + cell("E6", "Тестовый адрес, +7 (900) 111-22-33")
            + cell("AC5", "0011223344") + cell("AC6", "0000123456789") + cell("J7", "Тестовая модель") + cell("AE7", "А001АА999")
            + cell("N8", "120000") + (cached ? cell("AE8", end) : "<\(prefix)c r=\"AE8\"><\(prefix)f>SUM(N8,1)</\(prefix)f></\(prefix)c>")
            + cell("C47", "Проверкин Тест Тестович") + cell("C48", "(ФИО уполномоченного сотрудника)") + cell("D11", "BUDGET") + cell("AJ11", "POS") + extra
        let fuel = cell("A3", "Тестов Тест Тестович") + cell("C3", norm) + cell("A4", "Вид топлива") + cell("A5", "АИ-95") + cell("A6", "Итого по:") + cell("A8", "ФИО Тестов Т.Т.")
        let names = ["ПЛ-ТК", "СЗ-ТК", "Отчет по ТК ", "Список проектов"]
        let workbook = "<s:workbook xmlns:s=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:link=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><s:sheets>" + names.enumerated().map { "<s:sheet name=\"\($0.element)\" link:id=\"r\($0.offset)\"/>" }.joined() + "</s:sheets></s:workbook>"
        let rels = "<Relationships>" + names.indices.map { "<Relationship Id=\"r\($0)\" Target=\"worksheets/s\($0).xml\"/>" }.joined() + "</Relationships>"
        return try ZIPWriter.makeArchive(entries: [
            ("xl/workbook.xml", Data(workbook.utf8)), ("xl/_rels/workbook.xml.rels", Data(rels.utf8)),
            ("xl/worksheets/s0.xml", sheet(pl)), ("xl/worksheets/s1.xml", sheet(cell("C51", "Сотрудник") + cell("Q51", "Тестов Т. Т."))),
            ("xl/worksheets/s2.xml", sheet(fuel)), ("xl/worksheets/s3.xml", sheet(cell("A7", "Проект") + cell("B7", "BUDGET")))
        ])
    }
    static let projects = [GsmProjectOption(id: "pos", name: "Проект", budgetCode: "BUDGET"), GsmProjectOption(id: "alias", name: "Другой", budgetCode: "BUDGET")]
    static func rejected(_ data: Data, _ message: String) {
        do { _ = try GsmProfileXlsx.parse(data, expectedMonth: "2026-09", projects: projects); fatalError(message) }
        catch { checks += 1 }
    }
    static func replacing(_ data: Data, path: String, transform: (String) -> String) throws -> Data {
        let archive = try ZIPArchive(data: data)
        return try ZIPWriter.makeArchive(entries: archive.entries.keys.sorted().map { key in
            let part = try archive.extract(key)
            return (key, key == path ? Data(transform(String(decoding: part, as: UTF8.self)).utf8) : part)
        })
    }
    static func main() throws {
        if CommandLine.arguments.count == 2 { try fixture().write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        if CommandLine.arguments.count == 3 {
            let compressed = try GsmProfileXlsx.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), expectedMonth: "2026-09", projects: projects)
            check(compressed.profile.defaultStartOdometer == 123456, "Deflated XLSX must parse")
        }
        let january = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        check(GsmProfileXlsx.previousMonth(now: january, timeZone: TimeZone(secondsFromGMT: 10800)!) == "2025-12", "Previous period uses Gregorian year rollover")
        let boundary = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        check(GsmProfileXlsx.previousMonth(now: boundary, timeZone: TimeZone(secondsFromGMT: -14400)!) == "2026-08", "Previous period respects local timezone")
        let result = try GsmProfileXlsx.parse(fixture(), expectedMonth: "2026-09", projects: projects)
        check(result.profile.defaultStartOdometer == 123456, "Must use AE8, never N8")
        check(result.profile.reportStartMonth == "2026-10", "Next report month")
        check(result.profile.driverLicenseNumber == "0011223344", "Preserve leading zeros")
        check(result.profile.fuelCardNumber == "0000123456789", "Preserve card string")
        check(result.profile.employeeCompany == "ООО Тест, филиал", "Preserve company commas")
        check(result.profile.employeeJobTitle == "Инженер", "Separate title")
        check(result.profile.employeeAddress == "Тестовый адрес", "Split contact")
        check(result.profile.employeePhone == "+7(900)111-22-33", "Normalize phone")
        check(result.profile.employeeShortName == "Тестов Т. Т.", "Dynamic employee row")
        check(result.profile.authorizedShortName == "Проверкин Т. Т.", "Derive unambiguous initials")
        check(result.profile.employeeReportSignName == "Тестов Т.Т.", "Signature prefix only")
        check(result.profile.fuelTypes == ["АИ-95"], "Only selected fuels")
        check(result.profile.posProjectID == "pos", "Match budget and exact catalog name")
        check(result.profile.armProjectID == nil && result.profile.vehicleID == nil, "Never invent server IDs")
        check(result.sources["defaultStartOdometer"] == "ПЛ-ТК!AE8", "Exact source map")
        check(result.notes.contains { $0.contains("Остаток") || $0.contains("остатка") }, "Explain absent fuel balance")
        let plain = try GsmProfileXlsx.parse(fixture(prefix: ""), expectedMonth: "2026-09", projects: [])
        check(plain.profile.posProjectID == nil, "Offline catalog requires manual choice")
        let december = try GsmProfileXlsx.parse(fixture(month: "декабрь"), expectedMonth: "2026-12", projects: projects)
        check(december.profile.reportStartMonth == "2027-01", "Calendar year rollover")
        for end in ["-1", "1.5", "NaN", "inf", "2147483648"] { rejected(try fixture(end: end), "Invalid odometer accepted") }
        for norm in ["0", "-1", "NaN", "inf"] { rejected(try fixture(norm: norm), "Invalid norm accepted") }
        rejected(try fixture(month: "август"), "Wrong period accepted")
        rejected(try fixture(year: "2026.5"), "Fractional year accepted")
        rejected(try fixture(cached: false), "Uncached critical formula accepted")
        rejected(Data("not zip".utf8), "Invalid file accepted")
        rejected(try fixture(extra: "<s:c r=\"AE8\"><s:v>1</s:v></s:c>"), "Duplicate critical cell accepted")
        let direct = try replacing(fixture(), path: "xl/worksheets/s0.xml") {
            $0.replacingOccurrences(of: "<s:t>123456</s:t>", with: "<s:t></s:t>")
                .replacingOccurrences(of: "<s:c r=\"AE8\" t=\"inlineStr\"><s:is><s:t></s:t></s:is></s:c>", with: "<s:c r=\"AE8\"><s:f>$N$8</s:f></s:c>")
        }
        check(try GsmProfileXlsx.parse(direct, expectedMonth: "2026-09", projects: projects).profile.defaultStartOdometer == 120000, "Safe direct cell reference")
        let sharedFile = try replacing(fixture(), path: "xl/worksheets/s0.xml") {
            $0.replacingOccurrences(of: "<s:c r=\"AC5\" t=\"inlineStr\"><s:is><s:t>0011223344</s:t></s:is></s:c>", with: "<s:c r=\"AC5\" t=\"s\"><s:v>0</s:v></s:c>")
        }
        let sharedArchive = try ZIPArchive(data: sharedFile)
        var entries = try sharedArchive.entries.keys.sorted().map { (path: $0, data: try sharedArchive.extract($0)) }
        entries.append((path: "xl/sharedStrings.xml", data: Data("<s:sst xmlns:s=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><s:si><s:r><s:t>0011</s:t></s:r><s:r><s:t>223344</s:t></s:r></s:si></s:sst>".utf8)))
        let sharedResult = try GsmProfileXlsx.parse(ZIPWriter.makeArchive(entries: entries), expectedMonth: "2026-09", projects: projects)
        check(sharedResult.profile.driverLicenseNumber == "0011223344", "Namespace-aware rich shared strings preserve zeros")
        let cachedFormula = try replacing(fixture(), path: "xl/worksheets/s0.xml") {
            $0.replacingOccurrences(of: "<s:c r=\"AE8\" t=\"inlineStr\"><s:is><s:t>123456</s:t></s:is></s:c>", with: "<s:c r=\"AE8\"><s:f>SUM(N8,3456)</s:f><s:v>123456</s:v></s:c>")
        }
        check(try GsmProfileXlsx.parse(cachedFormula, expectedMonth: "2026-09", projects: projects).profile.defaultStartOdometer == 123456, "Use formula cache without executing it")
        let unsafe = try replacing(fixture(), path: "xl/workbook.xml") { "<!DOCTYPE workbook SYSTEM \"https://example.invalid/entity\">" + $0 }
        rejected(unsafe, "DTD accepted")
        let cyclic = try replacing(direct, path: "xl/worksheets/s0.xml") { $0.replacingOccurrences(of: "$N$8", with: "$AE$8") }
        rejected(cyclic, "Cyclic reference accepted")
        let oversized = try ZIPWriter.makeArchive(entries: [("one", Data(repeating: 0, count: 16 * 1024 * 1024 + 1))])
        rejected(oversized, "Oversized part accepted")
        let tooMany = try ZIPWriter.makeArchive(entries: (0..<513).map { ("part-\($0)", Data()) })
        rejected(tooMany, "Too many ZIP parts accepted")
        print("GSM XLSX import: \(checks) checks PASS")
    }
}
