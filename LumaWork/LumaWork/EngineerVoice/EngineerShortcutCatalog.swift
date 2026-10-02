import Foundation

nonisolated struct EngineerShortcutDefinition: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case information, request, wiki, ask
    }

    let id: String
    let title: String
    let section: String
    let kind: Kind
    let information: EngineerVoiceInformation?
    let period: EngineerVoicePeriod

    var requiresInput: Bool { kind != .information }
}

/// IDs are stored in imported shortcuts. Append aliases instead of reordering
/// existing aliases so that installed commands keep their original meaning.
nonisolated enum EngineerShortcutCatalog {
    static let commands: [EngineerShortcutDefinition] = {
        var result: [EngineerShortcutDefinition] = []
        func add(_ information: EngineerVoiceInformation, _ section: String, _ titles: [String], period: EngineerVoicePeriod = .currentMonth, idInformation: EngineerVoiceInformation? = nil) {
            for (index, title) in titles.enumerated() {
                result.append(EngineerShortcutDefinition(
                    id: "\((idInformation ?? information).rawValue).\(period.rawValue).\(index)",
                    title: title, section: section, kind: .information,
                    information: information, period: period
                ))
            }
        }
        let months: [EngineerVoicePeriod] = [.currentMonth, .previousMonth, .currentYear]
        let pastAndPresent: [EngineerVoicePeriod] = [.today, .yesterday] + months
        let days: [EngineerVoicePeriod] = [.today, .yesterday, .tomorrow]
        func suffix(_ period: EngineerVoicePeriod) -> String {
            switch period {
            case .today: "сегодня"
            case .yesterday: "вчера"
            case .tomorrow: "завтра"
            case .currentMonth: "за этот месяц"
            case .previousMonth: "за прошлый месяц"
            case .currentYear: "за этот год"
            }
        }
        func periodic(_ information: EngineerVoiceInformation, _ section: String, _ prefixes: [String], _ periods: [EngineerVoicePeriod]) {
            for period in periods {
                add(information, section, prefixes.map { "\($0) \(suffix(period))" }, period: period)
            }
        }

        add(.fuelDebt, "Топливо и пробег", ["Сколько бензина я должен", "Сколько топлива я должен", "Какой у меня долг за бензин"])
        periodic(.fuelBalance, "Топливо и пробег", ["Какой топливный баланс", "Какой остаток топлива по норме"], months)
        periodic(.fuelSummary, "Топливо и пробег", ["Сколько я заправил бензина", "Сколько я потратил на бензин"], months)
        periodic(.mileage, "Топливо и пробег", ["Какой пробег", "Сколько я проехал"], pastAndPresent)
        periodic(.compensation, "Топливо и пробег", ["Какая у меня компенсация за бензин", "Сколько осталось выплатить компенсации за бензин"], months)
        add(.fuelCard, "Топливо и пробег", ["Какой номер моей топливной карты", "Какая у меня топливная карта"])
        add(.fuelNorm, "Топливо и пробег", ["Какая у меня норма расхода топлива"])

        add(.vehicle, "Автомобиль", ["Какая у меня машина", "Какие данные моего автомобиля"])
        add(.vin, "Автомобиль", ["Какой у меня VIN", "Какой у меня вин номер"])
        add(.licensePlate, "Автомобиль", ["Какой у меня госномер", "Какой номер моей машины"])
        add(.sts, "Автомобиль", ["Какой номер моего СТС"])
        add(.pts, "Автомобиль", ["Какой номер моего ПТС"])
        add(.vehicleMileage, "Автомобиль", ["Какой пробег на одометре", "Какие показания одометра"])
        add(.vehicleDocuments, "Автомобиль", ["Какие документы на машину", "Какие файлы документов на машину"])
        add(.maintenance, "Автомобиль", ["Когда было последнее обслуживание машины", "Что я последний раз делал с машиной"])
        periodic(.maintenanceCosts, "Автомобиль", ["Сколько я потратил на обслуживание машины"], pastAndPresent)

        add(.activeRequests, "Заявки", ["Сколько у меня активных заявок", "Какие у меня активные заявки"])
        periodic(.dueRequests, "Заявки", ["Сколько у меня заявок"], days)
        for period in months {
            // Preserve IDs in already imported questions while correcting their
            // meaning: a month/year total comes from the closed-request archive.
            add(.closedRequests, "Заявки", ["Сколько у меня заявок \(suffix(period))"], period: period, idInformation: .dueRequests)
        }
        add(.overdueRequests, "Заявки", ["Сколько у меня просроченных заявок", "Какие заявки я просрочил"])
        periodic(.closedRequests, "Заявки", ["Сколько я закрыл заявок"], pastAndPresent)
        add(.returnEquipment, "Заявки", ["Какие у меня заявки на возврат оборудования"])
        add(.coordination, "Заявки", ["Сколько заявок у моей группы", "Что по заявкам нашей группы"])

        periodic(.route, "Маршрут", ["Что у меня по маршруту"], days)
        add(.nextStop, "Маршрут", ["Куда мне ехать дальше", "Какая следующая точка маршрута"], period: .today)

        add(.backpack, "Оборудование", ["Что у меня в рюкзаке", "Сколько оборудования в моём рюкзаке"])
        add(.officeEquipment, "Оборудование", ["Какое оборудование за мной закреплено", "Какое у меня оборудование"])

        add(.workSchedule, "График и трудозатраты", ["Я сегодня работаю", "Какой у меня график сегодня"], period: .today)
        add(.workSchedule, "График и трудозатраты", ["Я завтра работаю", "Какой у меня график завтра"], period: .tomorrow)
        add(.workSchedule, "График и трудозатраты", ["Сколько часов по графику вчера"], period: .yesterday)
        periodic(.workSchedule, "График и трудозатраты", ["Какой у меня график"], [.currentMonth, .previousMonth])
        periodic(.timeReports, "График и трудозатраты", ["Какие у меня трудозатраты", "Сколько времени я указал в отчётах"], pastAndPresent)

        periodic(.salary, "Выплаты и профиль", ["Сколько мне выплатили зарплаты"], pastAndPresent)
        add(.profile, "Выплаты и профиль", ["Какие у меня данные профиля", "Какой у меня табельный номер", "Какая у меня рабочая почта"])

        add(.workDocuments, "Документы и сервисы", ["Какие у меня рабочие документы"])
        add(.feedback, "Документы и сервисы", ["Что с моими обращениями", "Какие у меня обращения"])
        add(.ftpFiles, "Документы и сервисы", ["Какие папки на FTP"])
        add(.adminOverview, "Документы и сервисы", ["Как работает наш сервер"])

        for (kind, title, section) in [
            (EngineerShortcutDefinition.Kind.request, "Что по заявке", "Заявки"),
            (.wiki, "Найди рабочую инструкцию", "Документы и сервисы"),
            (.ask, "По работе", "Документы и сервисы")
        ] {
            result.append(EngineerShortcutDefinition(id: kind.rawValue, title: title, section: section,
                                                    kind: kind, information: nil, period: .today))
        }
        return result
    }()

    static var sections: [String] {
        commands.reduce(into: []) { if !$0.contains($1.section) { $0.append($1.section) } }
    }

    static func command(id: String) -> EngineerShortcutDefinition? {
        commands.first { $0.id == id }
    }

    /// Uses the workflow structure exported by Shortcuts on macOS 26.
    /// The build tool signs these files using Apple's `shortcuts sign` utility.
    static func workflowData(for command: EngineerShortcutDefinition, bundleIdentifier: String) throws -> Data {
        let intent: String
        var parameters: [String: Any] = ["UUID": UUID().uuidString]
        switch command.kind {
        case .information:
            intent = "EngineerPresetQuestionIntent"
            parameters["commandID"] = command.id
        case .request: intent = "EngineerRequestIntent"
        case .wiki: intent = "EngineerWikiIntent"
        case .ask: intent = "AskEngineerIntent"
        }
        let workflow: [String: Any] = [
            "WFWorkflowName": command.title,
            "WFWorkflowClientVersion": "3612.0.2.1",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconGlyphNumber": 61440, "WFWorkflowIconStartColor": 2071128575],
            "WFWorkflowActions": [["WFWorkflowActionIdentifier": "\(bundleIdentifier).\(intent)", "WFWorkflowActionParameters": parameters]],
            "WFWorkflowImportQuestions": [String](),
            "WFWorkflowInputContentItemClasses": [String](),
            "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowTypes": [String](),
            "WFQuickActionSurfaces": [String](),
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowHasOutputFallback": false
        ]
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }
}
