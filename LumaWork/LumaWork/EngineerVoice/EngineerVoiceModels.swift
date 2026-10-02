import Foundation

nonisolated enum EngineerVoicePeriod: String, CaseIterable, Sendable {
    case today, yesterday, tomorrow, currentMonth, previousMonth, currentYear

    var title: String {
        switch self {
        case .today: "сегодня"
        case .yesterday: "вчера"
        case .tomorrow: "завтра"
        case .currentMonth: "этот месяц"
        case .previousMonth: "прошлый месяц"
        case .currentYear: "этот год"
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component
        let date: Date
        switch self {
        case .today: component = .day; date = now
        case .yesterday: component = .day; date = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .tomorrow: component = .day; date = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        case .currentMonth: component = .month; date = now
        case .previousMonth: component = .month; date = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .currentYear: component = .year; date = now
        }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: now, duration: 0)
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let range = interval(now: now, calendar: calendar)
        return date >= range.start && date < range.end
    }
}

nonisolated enum EngineerVoiceInformation: String, CaseIterable, Sendable {
    case fuelDebt, fuelBalance, fuelSummary, mileage, compensation
    case vehicle, vin, licensePlate, sts, pts, vehicleMileage, vehicleDocuments
    case maintenance, maintenanceCosts, salary, profile, fuelCard, fuelNorm
    case activeRequests, dueRequests, overdueRequests, route, nextStop
    case backpack, officeEquipment, workSchedule, timeReports, workDocuments, feedback
    case closedRequests, returnEquipment, coordination, ftpFiles, adminOverview

    var title: String {
        switch self {
        case .fuelDebt: "долг за бензин"
        case .fuelBalance: "остаток по норме топлива"
        case .fuelSummary: "заправки и расходы"
        case .mileage: "пробег"
        case .compensation: "компенсацию ГСМ"
        case .vehicle: "данные автомобиля"
        case .vin: "VIN автомобиля"
        case .licensePlate: "госномер автомобиля"
        case .sts: "номер СТС"
        case .pts: "номер ПТС"
        case .vehicleMileage: "одометр автомобиля"
        case .vehicleDocuments: "документы автомобиля"
        case .maintenance: "последнее обслуживание"
        case .maintenanceCosts: "расходы на обслуживание"
        case .salary: "выплаты зарплаты"
        case .profile: "данные профиля"
        case .fuelCard: "номер топливной карты"
        case .fuelNorm: "норму расхода топлива"
        case .activeRequests: "активные заявки"
        case .dueRequests: "заявки по сроку"
        case .overdueRequests: "просроченные заявки"
        case .route: "маршрут"
        case .nextStop: "следующую точку маршрута"
        case .backpack: "содержимое рюкзака"
        case .officeEquipment: "моё оборудование"
        case .workSchedule: "график работы"
        case .timeReports: "трудозатраты"
        case .workDocuments: "рабочие документы"
        case .feedback: "статус обращений"
        case .closedRequests: "закрытые заявки"
        case .returnEquipment: "заявки на возврат ТО"
        case .coordination: "заявки группы"
        case .ftpFiles: "каталог FTP"
        case .adminOverview: "состояние сервера"
        }
    }
}

nonisolated enum EngineerVoiceText {
    static func isCurrentAssignee(id: String?, name: String, userID: String, username: String, displayName: String) -> Bool {
        if let id, !id.isEmpty { return id == userID }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "ru_RU"))
        guard !name.isEmpty else { return false }
        return [username, displayName].filter { !$0.isEmpty }.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "ru_RU")) == name
        }
    }
    static func period(in question: String) -> EngineerVoicePeriod? {
        let text = question.lowercased(with: Locale(identifier: "ru_RU"))
        if text.contains("прошл") && text.contains("месяц") { return .previousMonth }
        if text.contains("месяц") { return .currentMonth }
        if text.contains("вчера") { return .yesterday }
        if text.contains("завтра") { return .tomorrow }
        if text.contains("сегодня") { return .today }
        if text.contains("год") { return .currentYear }
        return nil
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2)))
    }

    static func fuelDebt(rubles: Double, estimatedLiters: Double) -> String {
        guard rubles > 0 else { return "Перенесённый денежный долг за бензин не записан. Перерасход по норме проверяется отдельно." }
        return "Перенесённый долг за бензин: \(number(rubles)) рублей, примерно \(number(estimatedLiters)) литра. Перевод в литры приблизительный."
    }

    static func fuelBalance(liters: Double) -> String {
        if liters < 0 { return "Перерасход по норме с учётом вычетов: \(number(abs(liters))) литра." }
        if liters > 0 { return "Остаток по норме с учётом вычетов: \(number(liters)) литра." }
        return "Расход соответствует норме."
    }

    static func matches(_ query: String, in text: String) -> Bool {
        let queryTokens = tokens(query)
        let textTokens = tokens(text)
        guard !queryTokens.isEmpty else { return false }
        if queryTokens.allSatisfy({ textTokens.contains($0) }) { return true }
        // Request/terminal numbers can be dictated with spaces. Do not use this
        // fallback for addresses: house 1 must never select house 10 or 10А.
        let compact = queryTokens.joined()
        return compact.contains(where: \.isNumber)
            && textTokens.contains(compact)
    }

    private static func tokens(_ text: String) -> [String] {
        let ignored = Set(["на", "по", "в", "заявка", "заявке", "пожалуйста", "г", "город", "д", "дом"])
        return text.lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignored.contains($0) }
            .map { $0 == "ул" ? "улица" : $0 }
    }

    static func spelledIdentifier(_ value: String) -> String {
        value.filter { !$0.isWhitespace }.map(String.init).joined(separator: ", ")
    }

    static func speech(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*`#]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The current assistant accepts 4,000 UTF-16 characters and its answer
    /// provider compacts the question to 2,400. Keep whole context items and put
    /// the actual question first, so routing never sees only our instructions.
    static func assistantMessage(question: String, context: [String]) -> String {
        var message = "Вопрос пользователя Инженера: " + String(question.prefix(600))
            + "\nСправочные данные приложения, только чтение:\n"
        let suffix = "\nОтветь кратко на русском для озвучивания Siri, без Markdown. Не выдумывай отсутствующие данные."
        for item in context {
            if (message + item + suffix).utf16.count > 2_300 {
                message += "Часть справочных данных не передана; не делай выводов об их отсутствии.\n"
                break
            }
            message += item + "\n"
        }
        return message + suffix
    }
}

nonisolated enum EngineerVoiceContext {
    static func directTopic(for question: String) -> EngineerVoiceInformation? {
        let text = question.lowercased(with: Locale(identifier: "ru_RU"))
        guard ["какой", "какая", "сколько", "назови", "покажи", "куда"].contains(where: text.hasPrefix),
              !["сравн", "почему", "разниц", "объясн", "втор", "другой", " и ", "январ", "феврал", "март", "апрел", "мае", "мая", "июн", "июл", "август", "сентябр", "октябр", "ноябр", "декабр"].contains(where: text.contains),
              !(text.contains("прошл") && text.contains("год")) else { return nil }
        if EngineerVoiceText.matches("vin", in: text) || EngineerVoiceText.matches("вин", in: text) { return .vin }
        if text.contains("одометр") { return .vehicleMileage }
        if text.contains("пробег") || text.contains("проехал") { return .mileage }
        if text.contains("бензин") || text.contains("топлив") {
            if text.contains("долг") || text.contains("должен") { return .fuelDebt }
        }
        if text.contains("заяв") {
            if text.contains("просроч") { return .overdueRequests }
            if text.contains("сегодня") || text.contains("срок") { return .dueRequests }
            if text.contains("актив") { return .activeRequests }
        }
        if text.contains("ехать") && text.contains("дальше") { return .nextStop }
        return nil
    }

    static func topics(for question: String) -> [EngineerVoiceInformation] {
        let text = question.lowercased(with: Locale(identifier: "ru_RU"))
        let groups: [(EngineerVoiceInformation, [String])] = [
            (.fuelDebt, ["бензин", "топлив", "долг", "перерасход"]),
            (.mileage, ["пробег", "километр", "проехал"]),
            (.fuelSummary, ["заправ", "бензин", "топлив"]),
            (.compensation, ["компенсац", "гсм", "удерж"]),
            (.vehicle, ["автомобил", "машин", "двигател"]),
            (.vin, ["vin", "вин"]), (.licensePlate, ["госномер"]),
            (.sts, ["стс"]), (.pts, ["птс"]),
            (.maintenance, ["обслужив", "ремонт", "масл", "детал"]),
            (.salary, ["зарплат", "аванс", "выплат", "доход", "получил денег"]),
            (.profile, ["табельн", "подразделен", "почт", "должност"]),
            (.fuelCard, ["топливная карта", "топливной карты"]), (.fuelNorm, ["норм", "расход"]),
            (.dueRequests, ["заявк"]), (.route, ["маршрут", "точк", "ехать"]),
            (.backpack, ["рюкзак"]), (.officeEquipment, ["оборудован"]),
            (.workSchedule, ["график", "смен", "работаю", "выходн"]),
            (.timeReports, ["трудозатрат", "переработ", "часов"]),
            (.workDocuments, ["документ"]), (.feedback, ["обращен", "обратн"]),
            (.closedRequests, ["закрыт", "закрыл"]), (.returnEquipment, ["возврат"]),
            (.coordination, ["заявки группы", "на группу"]), (.ftpFiles, ["ftp", "фтп"]),
            (.adminOverview, ["сервер", "vps"])
        ]
        var result = groups.filter { $0.1.contains(where: text.contains) }.map(\.0)
        if !EngineerVoiceText.matches("vin", in: text), !EngineerVoiceText.matches("вин", in: text) {
            result.removeAll { $0 == .vin }
        }
        if result.contains(.compensation), !["зарплат", "аванс", "доход"].contains(where: text.contains) {
            result.removeAll { $0 == .salary }
        }
        return result
    }
}
