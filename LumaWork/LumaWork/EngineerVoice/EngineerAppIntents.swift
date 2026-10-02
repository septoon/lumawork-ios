import AppIntents
import Foundation

nonisolated extension EngineerVoicePeriod: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Период"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "сегодня", .yesterday: "вчера", .tomorrow: "завтра",
        .currentMonth: "этот месяц", .previousMonth: "прошлый месяц", .currentYear: "этот год"
    ]
}

nonisolated extension EngineerVoiceInformation: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Данные Инженера"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .fuelDebt: "долг за бензин",
        .fuelBalance: "остаток по норме топлива",
        .fuelSummary: "заправки и расходы",
        .mileage: "пробег",
        .compensation: "компенсацию ГСМ",
        .vehicle: "данные автомобиля",
        .vin: "VIN автомобиля",
        .licensePlate: "госномер автомобиля",
        .sts: "номер СТС",
        .pts: "номер ПТС",
        .vehicleMileage: "одометр автомобиля",
        .vehicleDocuments: "документы автомобиля",
        .maintenance: "последнее обслуживание",
        .maintenanceCosts: "расходы на обслуживание",
        .salary: "выплаты зарплаты",
        .profile: "данные профиля",
        .fuelCard: "номер топливной карты",
        .fuelNorm: "норму расхода топлива",
        .activeRequests: "активные заявки",
        .dueRequests: "заявки по сроку",
        .overdueRequests: "просроченные заявки",
        .route: "маршрут",
        .nextStop: "следующую точку маршрута",
        .backpack: "содержимое рюкзака",
        .officeEquipment: "моё оборудование",
        .workSchedule: "график работы",
        .timeReports: "трудозатраты",
        .workDocuments: "рабочие документы",
        .feedback: "статус обращений",
        .closedRequests: "закрытые заявки",
        .returnEquipment: "заявки на возврат ТО",
        .coordination: "заявки группы",
        .ftpFiles: "каталог FTP",
        .adminOverview: "состояние сервера"
    ]

    var defaultPeriod: EngineerVoicePeriod {
        switch self {
        case .dueRequests, .route, .nextStop, .workSchedule, .timeReports: .today
        default: .currentMonth
        }
    }
}

@MainActor
private func engineerVoiceAnswer(
    _ operation: (EngineerVoiceDataService) async throws -> String
) async -> String {
    do { return try await operation(EngineerVoiceDataService()) }
    catch is CancellationError { return "Запрос отменён." }
    catch { return error.localizedDescription }
}

struct EngineerInformationIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать данные Инженера"
    static let description = IntentDescription("ГСМ, автомобиль, заявки, маршрут, оборудование, график, трудозатраты и документы. Только чтение.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Данные", requestValueDialog: "Что хотите узнать?")
    var information: EngineerVoiceInformation

    @Parameter(title: "Период")
    var period: EngineerVoicePeriod?

    static var parameterSummary: some ParameterSummary {
        Summary("Узнать \(\.$information)") { \.$period }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(information, period: period ?? information.defaultPeriod) }
        return .result(value: text, dialog: "\(text)")
    }
}

struct EngineerPresetQuestionIntent: AppIntent {
    static let title: LocalizedStringResource = "Ответить на готовый вопрос"
    static let description = IntentDescription("Готовая команда из каталога Siri в Инженере. Период и данные уже выбраны.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Команда")
    var commandID: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ответить на готовый вопрос") { \.$commandID }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { service in
            guard let command = EngineerShortcutCatalog.command(id: commandID), let information = command.information else {
                throw AppServiceError.message("Команда не найдена. Добавьте её заново из раздела «Siri и команды» в Инженере.")
            }
            return try await service.answer(information, period: command.period)
        }
        return .result(value: text, dialog: "\(text)")
    }
}

struct EngineerMileageIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать пробег"
    static let description = IntentDescription("Учтённый пробег по данным Инженера за выбранный период.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Период", default: .currentMonth)
    var period: EngineerVoicePeriod

    static var parameterSummary: some ParameterSummary { Summary("Узнать пробег: \(\.$period)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(.mileage, period: period) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerRequestEntity: AppEntity, Codable, Hashable {
    let id: String
    let name: String
    let address: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Заявка"
    static let defaultQuery = EngineerRequestQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", synonyms: ["\(address)"])
    }

    init(record: SimpleOneRequestRecord) {
        id = record.id
        address = record.address
        name = [record.address, record.number].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

nonisolated struct EngineerRequestQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [EngineerRequestEntity] {
        try await EngineerVoiceDataService().activeRequests()
            .filter { identifiers.contains($0.id) }.map(EngineerRequestEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [EngineerRequestEntity] {
        try await EngineerVoiceDataService().matchingRequests(string).map(EngineerRequestEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [EngineerRequestEntity] {
        EngineerVoiceRequestIndex.suggestions()
    }
}

struct EngineerRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать о заявке"
    static let description = IntentDescription("Найти свою активную заявку по адресу, номеру или терминалу и озвучить статус, срок и комментарий.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Адрес или номер", requestValueDialog: "Назовите адрес, номер заявки или терминала.")
    var query: String?

    @Parameter(title: "Заявка")
    var request: EngineerRequestEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Узнать о заявке") { \.$query; \.$request }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try EngineerVoiceDataService()
        let selected: EngineerRequestEntity
        if let request { selected = request }
        else {
            let text: String
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = query }
            else { text = try await $query.requestValue("Назовите адрес, номер заявки или терминала.") }
            let matches = try await service.matchingRequests(text).map(EngineerRequestEntity.init)
            guard !matches.isEmpty else {
                return .result(value: "Среди ваших активных заявок совпадений не найдено.", dialog: "Среди ваших активных заявок совпадений не найдено.")
            }
            if matches.count == 1 { selected = matches[0] }
            else { selected = try await $request.requestDisambiguation(among: matches, dialog: "Найдено несколько заявок. Какая нужна?") }
        }
        let text = try await service.requestAnswer(id: selected.id)
        return .result(value: text, dialog: "\(text)")
    }
}

struct AskEngineerIntent: AppIntent {
    static let title: LocalizedStringResource = "Спросить Инженера"
    static let description = IntentDescription("Продиктуйте произвольный вопрос. Ответ подготовит помощник Инженера. Требуется интернет.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Вопрос", requestValueDialog: "Что хотите спросить у Инженера?")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Спросить Инженера: \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.ask(question) }
        return .result(value: text, dialog: "\(text)")
    }
}

struct EngineerWikiIntent: AppIntent {
    static let title: LocalizedStringResource = "Найти инструкцию в Wiki"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Запрос", requestValueDialog: "Какую инструкцию найти?")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Найти в Wiki: \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.searchWiki(query) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerFuelDebtIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать долг за бензин"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(.fuelDebt, period: .currentMonth) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerVINIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать VIN автомобиля"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(.vin, period: .currentMonth) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerTodayRequestsIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать заявки на сегодня"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(.dueRequests, period: .today) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerNextStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать следующую точку"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await engineerVoiceAnswer { try await $0.answer(.nextStop, period: .today) }
        return .result(value: text, dialog: "\(text)")
    }
}

nonisolated struct EngineerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EngineerFuelDebtIntent(), phrases: [
            "Сколько бензина я должен в \(.applicationName)",
            "Какой долг за бензин в \(.applicationName)"
        ], shortTitle: "Долг за бензин", systemImageName: "fuelpump")
        AppShortcut(intent: EngineerMileageIntent(), phrases: [
            "Какой пробег в \(.applicationName)",
            "Какой пробег за \(\.$period) в \(.applicationName)"
        ], shortTitle: "Пробег", systemImageName: "speedometer")
        AppShortcut(intent: EngineerVINIntent(), phrases: [
            "Какой мой VIN в \(.applicationName)",
            "Узнай VIN в \(.applicationName)"
        ], shortTitle: "VIN автомобиля", systemImageName: "car")
        AppShortcut(intent: EngineerTodayRequestsIntent(), phrases: [
            "Сколько у меня заявок сегодня в \(.applicationName)",
            "Заявки на сегодня в \(.applicationName)"
        ], shortTitle: "Заявки на сегодня", systemImageName: "checklist")
        AppShortcut(intent: EngineerRequestIntent(), phrases: [
            "Что по заявке в \(.applicationName)",
            "Найди заявку в \(.applicationName)",
            "Что по заявке \(\.$request) в \(.applicationName)"
        ], shortTitle: "Информация по заявке", systemImageName: "doc.text.magnifyingglass")
        AppShortcut(intent: EngineerNextStopIntent(), phrases: [
            "Куда ехать дальше в \(.applicationName)",
            "Следующая точка в \(.applicationName)"
        ], shortTitle: "Следующая точка", systemImageName: "map")
        AppShortcut(intent: EngineerInformationIntent(), phrases: [
            "Узнай \(\.$information) в \(.applicationName)",
            "Узнай данные в \(.applicationName)"
        ], shortTitle: "Данные Инженера", systemImageName: "info.circle")
        AppShortcut(intent: AskEngineerIntent(), phrases: [
            "Спроси \(.applicationName)",
            "Задай вопрос в \(.applicationName)"
        ], shortTitle: "Спросить Инженера", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: EngineerWikiIntent(), phrases: [
            "Найди инструкцию в \(.applicationName)"
        ], shortTitle: "Поиск в Wiki", systemImageName: "book")
    }
}
