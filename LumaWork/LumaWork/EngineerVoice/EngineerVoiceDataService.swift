import Foundation
import LocalAuthentication

/// Read-only entry point for Siri. It does not construct screen stores, hydrate
/// the entire app, synchronize mileage, or update vehicles while reading them.
@MainActor
final class EngineerVoiceDataService {
    private let session: AppSession
    private let config = AppConfig()
    private var cachedFallbackDates: [Date] = []
    private let initialSimpleOneKey: String?
    private var salaryAuthenticated = false
    private var resolvedSimpleOneUser: SimpleOneUser?

    init() throws {
        guard let session = LumaWorkSessionKeychain.readSession(), !session.token.isEmpty else {
            throw AppServiceError.message("Откройте Инженер и войдите в приложение.")
        }
        self.session = session
        self.initialSimpleOneKey = SimpleOneSessionKeychain.readAuthKey()
    }

    private var profile: UserProfileData { session.user.profile ?? .empty }

    func validateSession() throws {
        try Task.checkCancellation()
        guard LumaWorkSessionKeychain.readSession() == session else {
            throw AppServiceError.message("Учётная запись изменилась. Повторите запрос.")
        }
        guard SimpleOneSessionKeychain.readAuthKey() == initialSimpleOneKey else {
            throw AppServiceError.message("Сессия SimpleOne изменилась. Повторите запрос.")
        }
    }

    private func load<Value: Codable>(
        _ type: Value.Type, key: String,
        fetch: () async throws -> Value
    ) async throws -> Value {
        try validateSession()
        let scopedKey = AppOfflineSnapshotStore.scopedKey(key, userID: session.user.id)
        let cached = AppOfflineSnapshotStore.load(type, key: scopedKey)
        if let cached, Date().timeIntervalSince(cached.updatedAt) < 60 {
            cachedFallbackDates.append(cached.updatedAt)
            return cached.value
        }
        do {
            let value = try await fetch()
            try validateSession()
            AppOfflineSnapshotStore.save(value, key: scopedKey)
            return value
        } catch {
            try validateSession()
            // Never return cached protected data after the API rejects a session.
            if case AppServiceError.http(let status, _) = error, status == 401 || status == 403 { throw error }
            if case SimpleOneServiceError.unauthorized = error { throw error }
            guard let cached else { throw error }
            cachedFallbackDates.append(cached.updatedAt)
            return cached.value
        }
    }

    func finish(_ answer: String) throws -> String {
        try validateSession()
        guard let date = cachedFallbackDates.min() else { return answer }
        return answer + " Данные из кеша, обновлены " + date.formatted(
            .dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU"))
        ) + "."
    }

    private func fuel(currentBalance: Bool) async throws -> FuelSummary {
        let service = FuelService(config: config, authToken: session.token)
        let records = try await load([FuelRecord].self, key: "fuel") { try await service.fetchRecords() }
        guard !records.isEmpty else { throw AppServiceError.message("Данных по ГСМ пока нет.") }
        let projection = currentBalance ? FuelProjection.current(records: records) : FuelProjection(records: records)
        guard projection.summary.hasData else {
            throw AppServiceError.message("В текущем разделе «Топливо» пока нет данных.")
        }
        return projection.summary
    }

    private func vehicles() async throws -> [Vehicle] {
        let api = VehicleAPI(config: config, authToken: session.token)
        return try await load([Vehicle].self, key: "vehicles") { try await api.fetchVehicles() }
            .map { $0.fillingMissingFields(from: profile) }
    }

    private func primaryVehicle() async throws -> Vehicle {
        let values = try await vehicles()
        guard let vehicle = values.first(where: \.isPrimary) ?? (values.count == 1 ? values.first : nil) else {
            throw AppServiceError.message(values.isEmpty ? "Автомобиль не добавлен." : "Укажите основной автомобиль в Инженере.")
        }
        return vehicle
    }

    private func simpleOneSession() async throws -> (key: String, user: SimpleOneUser) {
        guard let key = SimpleOneSessionKeychain.readAuthKey() else {
            throw SimpleOneServiceError.missingCredentials
        }
        let user: SimpleOneUser
        if let resolvedSimpleOneUser { user = resolvedSimpleOneUser }
        else {
            user = try await SimpleOneRequestsService().fetchCurrentUser(authKey: key)
            resolvedSimpleOneUser = user
        }
        guard SimpleOneSessionKeychain.readAuthKey() == key else { throw CancellationError() }
        return (key, user)
    }

    func activeRequests() async throws -> [SimpleOneRequestRecord] {
        let auth = try await simpleOneSession()
        return try await load([SimpleOneRequestRecord].self, key: "voice-active-requests-\(auth.user.sysID)") {
            let records = try await SimpleOneRequestsService().fetchActiveRequests(userID: auth.user.sysID, authKey: auth.key)
            guard SimpleOneSessionKeychain.readAuthKey() == auth.key else { throw CancellationError() }
            return records
        }
    }

    func matchingRequests(_ query: String) async throws -> [SimpleOneRequestRecord] {
        try await activeRequests().filter {
            EngineerVoiceText.matches(query, in: $0.address)
                || EngineerVoiceText.matches(query, in: $0.number)
                || EngineerVoiceText.matches(query, in: $0.incomingNumber)
                || EngineerVoiceText.matches(query, in: $0.terminalID)
                || EngineerVoiceText.matches(query, in: $0.customer)
        }
    }

    func requestAnswer(id: String) async throws -> String {
        guard let record = try await activeRequests().first(where: { $0.id == id }) else {
            throw AppServiceError.message("Заявка больше не найдена среди ваших активных заявок.")
        }
        let auth = try await simpleOneSession()
        let detailed = try await SimpleOneRequestsService().fetchRequestDetails(record: record, authKey: auth.key)
        guard SimpleOneSessionKeychain.readAuthKey() == auth.key else { throw CancellationError() }
        let values = [
            "Заявка \(detailed.number). \(detailed.address).",
            "Статус: \(detailed.state).",
            detailed.shortDescription,
            detailed.deadline.isEmpty ? "" : "Срок: \(detailed.deadline).",
            detailed.waitingReason.map { "Причина ожидания: \($0)." } ?? "",
            detailed.engineerComment.isEmpty ? "" : "Комментарий инженера: \(detailed.engineerComment)."
        ]
        return try finish(values.filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func days() async throws -> [RouteDayRecord] {
        let service = RouteDayService(config: config, authToken: session.token)
        let settings = RouteSettings(
            warehouseAddress: profile.routeWarehouseAddress ?? RouteSettings.officeAddress,
            homeAddress: profile.routeHomeAddress ?? ""
        )
        return try await load([RouteDayRecord].self, key: "voice-route-days") {
            try await service.fetchAllDays(settings: settings)
        }
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "dd.MM.yyyy", "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func authenticateSalary() async throws {
        guard !salaryAuthenticated else { return }
        guard UserDefaults.standard.bool(forKey: SalaryPasscodeSettings.faceIDEnabledKey)
                || UserDefaults.standard.object(forKey: SalaryPasscodeSettings.faceIDEnabledKey) == nil else {
            throw AppServiceError.message("Для зарплаты включите Face ID или откройте раздел «Зарплата» и введите PIN.")
        }
        let context = LAContext()
        guard SalaryPasscodeSettings.isFaceIDAvailable(using: context) else {
            throw AppServiceError.message("Откройте раздел «Зарплата» в Инженере и пройдите проверку доступа.")
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Озвучить данные зарплаты") else {
            throw AppServiceError.message("Доступ к зарплате не подтверждён.")
        }
        salaryAuthenticated = true
    }

    func answer(_ information: EngineerVoiceInformation, period: EngineerVoicePeriod) async throws -> String {
        let n = EngineerVoiceText.number
        let result: String
        switch information {
        case .fuelDebt, .fuelBalance, .fuelSummary, .mileage, .compensation:
            if information == .mileage && [.today, .yesterday, .tomorrow].contains(period) {
                let records = try await days().filter { parseDate($0.date).map { period.contains($0) } ?? false }
                guard !records.isEmpty else { return try finish("За период «\(period.title)» маршрутов нет.") }
                guard records.allSatisfy({ $0.distanceKm != nil }) else { throw AppServiceError.message("В части маршрутов пробег не заполнен. Откройте Инженер и проверьте отчёты.") }
                return try finish("Учтённый пробег за период «\(period.title)»: \(n(records.reduce(0) { $0 + Double($1.distanceKm ?? 0) })) километров.")
            }
            let summary = try await fuel(currentBalance: information == .fuelDebt || information == .fuelBalance)
            let range = period.interval()
            let selected = summary.monthly.filter { month in
                guard let date = parseDate(month.key + "-01") else { return false }
                return date >= range.start && date < range.end
            }
            if information == .fuelDebt {
                result = "Текущий топливный баланс: " + EngineerVoiceText.fuelBalance(liters: summary.totals.adjustedFuelDiff)
            } else if information == .fuelBalance {
                guard [.currentMonth, .previousMonth, .currentYear].contains(period) else { throw AppServiceError.message("Для остатка по норме выберите месяц или год.") }
                guard !selected.isEmpty else { return try finish("Данных ГСМ за период «\(period.title)» нет.") }
                result = "За период «\(period.title)»: " + EngineerVoiceText.fuelBalance(liters: selected.reduce(0) { $0 + $1.fuelDiff + $1.effectiveDebtDeductionLiters })
            } else if information == .mileage || information == .fuelSummary || information == .compensation {
                guard period == .currentMonth || period == .previousMonth || period == .currentYear else {
                    throw AppServiceError.message("Для сводки ГСМ выберите месяц или год.")
                }
                guard !selected.isEmpty else { return try finish("Данных ГСМ за период «\(period.title)» нет.") }
                if information == .mileage {
                    result = "Учтённый пробег за период «\(period.title)»: \(n(selected.reduce(0) { $0 + $1.totalMileage })) километров."
                } else if information == .fuelSummary {
                    result = "За период «\(period.title)» заправлено \(n(selected.reduce(0) { $0 + $1.totalLiters })) литра, по норме \(n(selected.reduce(0) { $0 + $1.fuelNorm })) литра, расходы \(n(selected.reduce(0) { $0 + $1.fuelCost })) рублей. "
                        + EngineerVoiceText.fuelBalance(liters: selected.reduce(0) { $0 + $1.fuelDiff + $1.effectiveDebtDeductionLiters })
                } else {
                    result = "Компенсация за период «\(period.title)»: начислено \(n(selected.reduce(0) { $0 + $1.compensation })), выплачено \(n(selected.reduce(0) { $0 + $1.paidCompensation })), удержано \(n(selected.reduce(0) { $0 + $1.effectiveDebtDeductionAmount })), расчётный остаток к выплате \(n(selected.reduce(0) { $0 + $1.projectedPayout })) рублей."
                }
            } else { result = "Данных нет." }

        case .vehicle, .vin, .licensePlate, .sts, .pts, .vehicleMileage, .vehicleDocuments:
            let car = try await primaryVehicle()
            switch information {
            case .vin:
                guard let vin = UserProfileData.clean(car.vin) else { throw AppServiceError.message("VIN не заполнен.") }
                result = "VIN автомобиля \(car.displayName): \(EngineerVoiceText.spelledIdentifier(vin))."
            case .licensePlate: result = "Госномер: \(car.licensePlate ?? "не заполнен")."
            case .sts: result = "Номер СТС: \(car.sts ?? "не заполнен")."
            case .pts: result = "Номер ПТС: \(car.pts ?? "не заполнен")."
            case .vehicleMileage: result = car.currentMileageKm.map { "Записанный одометр автомобиля: \($0) километров." } ?? "Одометр автомобиля не заполнен."
            case .vehicleDocuments:
                let documents = car.documents ?? []
                result = "Документов автомобиля: \(documents.count). " + documents.prefix(5).map { "\($0.kind.title): \($0.fileName)" }.joined(separator: ". ")
            default:
                result = "Основной автомобиль: \(car.displayName). Госномер: \(car.licensePlate ?? "не заполнен"). Год: \(car.year.map(String.init) ?? "не заполнен"). Объём двигателя: \(car.engineVolumeCm3.map(String.init) ?? "не заполнен") кубических сантиметров. Мощность: \(car.enginePowerHp.map(String.init) ?? "не заполнена") лошадиных сил."
            }

        case .maintenance, .maintenanceCosts:
            let service = MaintenanceService(config: config, authToken: session.token)
            let car = try await primaryVehicle()
            let records = try await load([MaintenanceRecord].self, key: "maintenance") { try await service.fetchRecords() }
                .filter { $0.vehicleID == car.id || ($0.vehicleID == nil && car.isPrimary) }
            if information == .maintenance {
                guard let last = records.sorted(by: { $0.date > $1.date }).first else { return try finish("Обслуживание автомобиля не записано.") }
                result = "Последнее обслуживание \(car.displayName): \(last.date), \(last.procedure), при пробеге \(last.mileage) километров. Стоимость: \(n(last.totalCost ?? (last.parts.reduce(0) { $0 + $1.cost } + (last.workCost ?? 0)))) рублей."
            } else {
                let selected = records.filter { parseDate($0.date).map { period.contains($0) } ?? false }
                result = "Расходы на обслуживание за период «\(period.title)»: \(n(selected.reduce(0) { $0 + ($1.totalCost ?? ($1.parts.reduce(0) { $0 + $1.cost } + ($1.workCost ?? 0))) })) рублей. Записей: \(selected.count)."
            }

        case .salary:
            try await authenticateSalary()
            let service = SalaryService(config: config, authToken: session.token)
            let months = try await load([SalaryMonth].self, key: "salary") { try await service.fetchMonths() }
            let entries = months.flatMap(\.entries).filter { parseDate($0.date).map { period.contains($0) } ?? false }
            result = "Записанные выплаты за период «\(period.title)»: \(n(entries.reduce(0) { $0 + SalaryCalculations.payout(for: $1) })) рублей, записей: \(entries.count)."

        case .profile:
            result = [
                [profile.lastName, profile.firstName, profile.middleName].compactMap { $0 }.joined(separator: " "),
                "Должность: \(profile.jobTitle ?? "не заполнена")",
                "Подразделение: \(profile.departmentTitle ?? "не заполнено")",
                "Табельный номер: \(profile.personnelNumber ?? "не заполнен")",
                "Рабочая почта: \(profile.workEmail ?? session.user.email)"
            ].joined(separator: ". ")

        case .fuelCard, .fuelNorm:
            let api = GsmProfileAPI(config: config, authToken: session.token)
            let gsm = try await load(GsmProfile.self, key: "voice-gsm-profile") { try await api.fetchProfile().profile }
            result = information == .fuelCard ? "Топливная карта: \(gsm.fuelCardNumber.isEmpty ? "не заполнена" : gsm.fuelCardNumber)." : "Норма расхода в профиле ГСМ: \(n(gsm.fuelNorm)) литра на 100 километров."

        case .activeRequests, .dueRequests, .overdueRequests:
            let records = try await activeRequests()
            let selected: [SimpleOneRequestRecord]
            if information == .dueRequests { selected = records.filter { $0.deadlineDate.map { period.contains($0) } ?? false } }
            else if information == .overdueRequests { selected = records.filter(\.isOverdue) }
            else { selected = records }
            result = "\(information == .dueRequests ? "Заявок со сроком за период «\(period.title)»" : information.title.capitalized): \(selected.count). "
                + selected.sorted { ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture) }.prefix(3).map { "\($0.address), \($0.state), срок \($0.deadline)" }.joined(separator: ". ")

        case .route, .nextStop:
            let records = try await days().filter { parseDate($0.date).map { period.contains($0) } ?? false }
            guard !records.isEmpty else { return try finish("Маршрут за период «\(period.title)» на сервере не найден. Несохранённые изменения доступны в приложении.") }
            if information == .nextStop {
                guard records.count == 1 else { throw AppServiceError.message("Найдено несколько маршрутов. Откройте Инженер и выберите маршрут.") }
                let stops = records[0].stops.dropFirst().dropLast()
                result = stops.first(where: { $0.status == .pending }).map { "Следующая точка: \($0.address). \($0.org). \($0.reason)." } ?? "Невыполненных рабочих точек в маршруте нет."
            } else {
                let stops = records.flatMap { Array($0.stops.dropFirst().dropLast()) }
                result = "Маршрутов: \(records.count). Рабочих точек: \(stops.count), выполнено: \(stops.filter { $0.status == .done }.count), осталось: \(stops.filter { $0.status == .pending }.count). Отправленных отчётов: \(records.filter(\.sent).count)."
            }

        case .backpack:
            guard let key = SimpleOneSessionKeychain.readAuthKey() else { throw SimpleOneServiceError.missingCredentials }
            let items = try await load([BackpackItem].self, key: "backpack") { try await BackpackService().fetchItems(authKey: key) }
            guard SimpleOneSessionKeychain.readAuthKey() == key else { throw CancellationError() }
            result = "В рюкзаке \(items.reduce(0) { $0 + max($1.quantity, 0) }) единиц оборудования. " + items.prefix(5).map { "\($0.name): \($0.quantity)" }.joined(separator: ". ")

        case .officeEquipment:
            guard let key = SimpleOneSessionKeychain.readAuthKey() else { throw SimpleOneServiceError.missingCredentials }
            let items = try await load([OfficeEquipmentItem].self, key: "office-equipment") { try await SimpleOneRequestsService().fetchCurrentOfficeEquipment(authKey: key) }
            guard SimpleOneSessionKeychain.readAuthKey() == key else { throw CancellationError() }
            result = "За вами закреплено \(items.count) единиц оборудования. " + items.prefix(5).map { "\($0.displayName), серийный номер \($0.serialNumber)" }.joined(separator: ". ")

        case .workSchedule:
            guard period != .currentYear else { throw AppServiceError.message("Для графика работы выберите день или месяц.") }
            let auth = try await simpleOneSession()
            let service = SimpleOneRequestsService()
            let date = period.interval().start
            let parts = Calendar.current.dateComponents([.year, .month], from: date)
            let journals = try await service.fetchWorkScheduleJournals(authKey: auth.key)
            let matching = journals.filter {
                $0.year == parts.year && $0.month == parts.month
                    && (UserProfileData.clean(profile.city) == nil || $0.cityName.caseInsensitiveCompare(profile.city ?? "") == .orderedSame)
            }
            guard matching.count == 1, let journal = matching.first else { throw AppServiceError.message("Не удалось однозначно выбрать график. Проверьте город профиля и график в Инженере.") }
            let schedule = try await service.fetchWorkSchedule(journal: journal, authKey: auth.key)
            guard SimpleOneSessionKeychain.readAuthKey() == auth.key else { throw CancellationError() }
            guard let employee = schedule.employees.first(where: { $0.login.caseInsensitiveCompare(auth.user.username) == .orderedSame }) else { throw AppServiceError.message("Ваша строка в графике не найдена.") }
            if period == .today || period == .yesterday || period == .tomorrow {
                let day = Calendar.current.component(.day, from: date)
                guard let value = employee.dayValues.first(where: { $0.day == day }) else { throw AppServiceError.message("День в графике не заполнен.") }
                result = "По графику за период «\(period.title)»: \(n(value.hours)) часов."
            } else { result = "По графику за \(journal.month).\(journal.year): \(n(employee.totalHours)) часов." }

        case .timeReports:
            let auth = try await simpleOneSession()
            let entries = try await SimpleOneRequestsService().fetchTimeReportEntries(authKey: auth.key).filter { period.contains($0.effectiveWorkDate) }
            guard SimpleOneSessionKeychain.readAuthKey() == auth.key else { throw CancellationError() }
            result = "Трудозатраты за период «\(period.title)»: работа \(entries.reduce(0) { $0 + $1.workMinutes }) минут, дорога \(entries.reduce(0) { $0 + $1.travelMinutes }) минут, переработки \(entries.reduce(0) { $0 + $1.overtimeMinutes }) минут."

        case .workDocuments:
            let api = WorkDocumentsAPI(config: config, token: session.token)
            let items = try await load([WorkDocument].self, key: "voice-work-documents") { try await api.fetch() }
            result = "Рабочих документов: \(items.count). " + items.prefix(5).map(\.title).joined(separator: ". ")

        case .feedback:
            let api = FeedbackAPI(config: config)
            let items = try await api.fetchMessages(token: session.token)
            result = "Обращений: \(items.count). " + items.prefix(5).map { "\($0.number), \($0.title): \($0.status.title)" }.joined(separator: ". ")

        case .closedRequests:
            let auth = try await simpleOneSession()
            guard let snapshot = ClosedSimpleOneRequestsStore.completeVoiceSnapshot(for: auth.user.sysID) else {
                throw AppServiceError.message("Откройте архив закрытых заявок в Инженере и дождитесь полной загрузки.")
            }
            let records = snapshot.records.filter {
                EngineerVoiceText.isCurrentAssignee(id: $0.assignedUserID, name: $0.assignedUser, userID: auth.user.sysID, username: auth.user.username, displayName: auth.user.displayName)
                    && (parseDate($0.closedAt ?? "") ?? parseDate($0.resolvedAt)).map { period.contains($0) } == true
            }
            cachedFallbackDates.append(snapshot.updatedAt)
            result = "Ваших закрытых заявок за период «\(period.title)»: \(records.count). "
                + records.prefix(3).map { "\($0.number): \($0.resolution ?? $0.engineerComment)" }.joined(separator: ". ")

        case .returnEquipment:
            let auth = try await simpleOneSession()
            let records = try await SimpleOneRequestsService().fetchReturnEquipmentRequests(userID: auth.user.sysID, authKey: auth.key)
            result = "Ваших заявок на возврат ТО: \(records.count). " + records.prefix(5).map { "\($0.number), \($0.terminalModel), \($0.state)" }.joined(separator: ". ")

        case .coordination:
            let auth = try await simpleOneSession()
            guard let city = UserProfileData.clean(profile.city),
                  let region = CoordinationRegion.allCases.first(where: { $0.title.caseInsensitiveCompare(city) == .orderedSame }) else {
                throw AppServiceError.message("Для заявок группы укажите город в профиле Инженера.")
            }
            let records = try await SimpleOneRequestsService().fetchCoordinationRequests(region: region, authKey: auth.key)
            result = "Активных заявок группы в городе \(region.title): \(records.count). Просрочено: \(records.filter(\.isOverdue).count)."

        case .ftpFiles:
            let directory = try await FTPAPI(config: config, authToken: session.token).files(path: "/")
            result = "В корне FTP: \(directory.items.filter(\.isDirectory).count) папок, \(directory.items.filter { !$0.isDirectory }.count) файлов. "
                + directory.items.prefix(8).map(\.name).joined(separator: ". ")

        case .adminOverview:
            guard session.user.can(.viewOverview) else { throw AppServiceError.message("Нет доступа к обзору админки.") }
            let context = LAContext()
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Озвучить данные админки") else { throw AppServiceError.message("Доступ к админке не подтверждён.") }
            let overview = try await AdminOverviewAPI(config: config).fetch(token: session.token)
            result = "Сервис \(overview.system.service): \(overview.system.status). Пользователей: \(overview.stats.users), активных за неделю: \(overview.stats.activeUsers7d). Автомобилей: \(overview.stats.vehicles)."
            if let resources = overview.resources {
                return try finish(result + " Загрузка процессора \(n(resources.cpuUsagePercent)) процентов, память \(n(resources.ramUsagePercent)) процентов, диск \(n(resources.diskUsagePercent)) процентов.")
            }
        }
        return try finish(result)
    }

    func searchWiki(_ query: String) async throws -> String {
        let page = try await WikiAPI(config: config).search(query: query, limit: 3)
        guard !page.results.isEmpty else { return try finish("В Wiki ничего не найдено.") }
        return try finish(page.results.map { "\($0.title). \($0.excerpt)" }.joined(separator: " "))
    }

    func ask(_ question: String) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AppServiceError.message("Вопрос пустой.") }
        guard question.count <= 600 else { throw AppServiceError.message("Вопрос слишком длинный. Сформулируйте его короче.") }
        if let topic = EngineerVoiceContext.directTopic(for: question) {
            return try await answer(topic, period: EngineerVoiceText.period(in: question) ?? topic.defaultPeriod)
        }
        let api = AssistantAPI(config: config, authToken: session.token)
        let simpleOneStore = SimpleOneRequestsStore(automaticallyRefresh: false)
        let executor = AssistantLocalToolExecutor(simpleOneStore: simpleOneStore, backpackStore: BackpackStore(cacheID: session.user.id))
        var context: [String] = []
        // Add only sources relevant to the question, with exact app calculations.
        // The assistant's server tools remain available for the other sources.
        for topic in EngineerVoiceContext.topics(for: question) {
            // Failure to authorize salary must stop the request, rather than
            // falling through to a server-generated answer about protected data.
            if topic == .salary { try await authenticateSalary() }
            do {
                let period = EngineerVoiceText.period(in: question) ?? topic.defaultPeriod
                context.append(try await answer(topic, period: period))
                if [.mileage, .fuelSummary, .compensation, .salary, .maintenanceCosts].contains(topic) {
                    let other: EngineerVoicePeriod = period == .previousMonth ? .currentMonth : .previousMonth
                    context.append(try await answer(topic, period: other))
                }
            } catch {
                context.append("\(topic.title): данные недоступны. \(error.localizedDescription)")
            }
        }
        try validateSession()
        let message = EngineerVoiceText.assistantMessage(question: question, context: context)
        let conversationID = UUID()
        let requestID = UUID()
        var results: [AssistantAPIToolResult]?
        for cycle in 0...2 {
            let envelope = try await api.run(message: message, conversationID: conversationID, requestID: requestID, currentScreen: "siri", toolResults: results)
            try validateSession()
            switch envelope.result {
            case .answer(let text, _, _, _, _, _): return try finish(EngineerVoiceText.speech(text))
            case .blocked(let text, _), .conversationFull(let text, _): return try finish(EngineerVoiceText.speech(text))
            case .toolRequest(let requests, _, _):
                guard cycle < 2 else { throw AppServiceError.message("Не удалось получить данные для ответа. Попробуйте более короткий вопрос.") }
                if requests.contains(where: { ["active_requests", "request_details"].contains($0.name) }) {
                    let auth = try await simpleOneSession()
                    simpleOneStore.currentUser = auth.user
                    simpleOneStore.activeRequests = try await activeRequests()
                    simpleOneStore.lastUpdatedAt = Date()
                }
                results = try await executor.execute(requests)
            }
        }
        throw AppServiceError.message("Помощник не вернул ответ.")
    }
}
