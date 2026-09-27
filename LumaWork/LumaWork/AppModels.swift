import Foundation

struct MaintenancePart: Codable, Hashable {
    var name: String
    var cost: Double
}

struct MaintenanceRecord: Codable, Hashable {
    var id: String?
    var vehicleID: String?
    var date: String
    var procedure: String
    var mileage: Int
    var parts: [MaintenancePart]
    var workCost: Double?
    var totalCost: Double?

    var stableID: String {
        id ?? "\(date)|\(procedure)|\(mileage)|\(parts.map(\.name).joined(separator: ","))|\(workCost ?? -1)"
    }
}

struct MaintenanceRecordInput {
    var vehicleID: String?
    var date: String
    var procedure: String
    var mileage: Int
    var parts: [MaintenancePart]
    var workCost: Double?
}

struct FuelRecord: Codable, Hashable {
    enum RecordType: String, Codable {
        case fuel
        case adjustment
    }

    enum AdjustmentKind: String, Codable {
        case compensationPayment = "compensation_payment"
        case debtDeduction = "debt_deduction"
    }

    var id: String?
    var recordType: RecordType
    var adjustmentKind: AdjustmentKind?
    var monthKey: String?
    var amount: Double?
    var carryoverDebtRub: Double?
    var comment: String?
    var date: String
    var mileage: Double?
    var liters: Double?
    var fuelCost: Double?
    var fuelType: String? = nil
    var fuelConsumptionRate: Double? = nil
    var source: String? = nil
    var sourceImportId: String? = nil

    var stableID: String {
        id ?? "\(recordType.rawValue)|\(adjustmentKind?.rawValue ?? "")|\(monthKey ?? "")|\(date)|\(mileage ?? -1)|\(liters ?? -1)|\(fuelCost ?? -1)|\(fuelType ?? "")|\(amount ?? -1)"
    }
}

struct FuelRecordInput {
    var recordType: FuelRecord.RecordType
    var adjustmentKind: FuelRecord.AdjustmentKind?
    var monthKey: String?
    var amount: Double?
    var carryoverDebtRub: Double?
    var comment: String?
    var date: String
    var mileage: Double?
    var liters: Double?
    var fuelCost: Double?
    var fuelType: String? = nil
}

struct SalaryEntry: Codable, Hashable {
    var id: String?
    var date: String
    var baseSalary: Double
    var weekendPay: Double
    var periodMonth: String?
    var amount: Double?
    var kind: SalaryPaymentKind?
    var comment: String?

    var stableID: String {
        id ?? "\(date)|\(baseSalary)|\(weekendPay)|\(periodMonth ?? "")|\(amount ?? 0)|\(kind?.rawValue ?? "")|\(comment ?? "")"
    }
}

struct SalaryEntryInput {
    var date: String
    var baseSalary: Double
    var weekendPay: Double
    var periodMonth: String?
    var amount: Double?
    var kind: SalaryPaymentKind?
    var comment: String?
}

struct SalaryMonth: Codable, Hashable {
    var month: String
    var entries: [SalaryEntry]
}

enum SalaryPaymentKind: String, CaseIterable, Codable, Hashable {
    case advance
    case salary
    case weekend
    case gsm
    case other

    var title: String {
        switch self {
        case .advance:
            return "Аванс"
        case .salary:
            return "Зарплата"
        case .weekend:
            return "Работа в выходной"
        case .gsm:
            return "Компенсация ГСМ"
        case .other:
            return "Другое"
        }
    }
}

enum RouteWorkType: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case pos = "POS"
    case arm = "ARM"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pos:
            return "POS"
        case .arm:
            return "АРМ"
        }
    }

    func storageKey(for date: String) -> String {
        self == .pos ? date : "\(date)|\(rawValue)"
    }
}

enum RouteStopStatus: String, Codable, Hashable {
    case pending
    case done
    case declined
}

struct RouteStop: Codable, Hashable, Identifiable {
    var id: String
    var address: String
    var org: String
    var tid: String
    var reason: String
    var status: RouteStopStatus
    var declineReason: String
    var requestNumber: String
}

struct RouteDayRecord: Codable, Hashable {
    var date: String
    var workType: RouteWorkType
    var stops: [RouteStop]
    var distanceKm: Int?
    var periodStartOdometer: Int?
    var reportedDistanceKm: Double? = nil
    var routeSummary: String? = nil
    var requestNumbersSummary: String? = nil
    var reportedPeriodStartOdometer: Int? = nil
    var fuelDate: String? = nil
    var fuelLiters: Double? = nil
    var fuelCostRub: Double? = nil
    var sent: Bool

    init(
        date: String,
        workType: RouteWorkType = .pos,
        stops: [RouteStop],
        distanceKm: Int? = nil,
        periodStartOdometer: Int? = nil,
        reportedDistanceKm: Double? = nil,
        routeSummary: String? = nil,
        requestNumbersSummary: String? = nil,
        reportedPeriodStartOdometer: Int? = nil,
        fuelDate: String? = nil,
        fuelLiters: Double? = nil,
        fuelCostRub: Double? = nil,
        sent: Bool
    ) {
        self.date = date
        self.workType = workType
        self.stops = stops
        self.distanceKm = distanceKm
        self.periodStartOdometer = periodStartOdometer
        self.reportedDistanceKm = reportedDistanceKm
        self.routeSummary = routeSummary
        self.requestNumbersSummary = requestNumbersSummary
        self.reportedPeriodStartOdometer = reportedPeriodStartOdometer
        self.fuelDate = fuelDate
        self.fuelLiters = fuelLiters
        self.fuelCostRub = fuelCostRub
        self.sent = sent
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case workType
        case stops
        case distanceKm
        case periodStartOdometer
        case reportedDistanceKm
        case routeSummary
        case requestNumbersSummary
        case reportedPeriodStartOdometer
        case fuelDate
        case fuelLiters
        case fuelCostRub
        case sent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        workType = try container.decodeIfPresent(RouteWorkType.self, forKey: .workType) ?? .pos
        stops = try container.decodeIfPresent([RouteStop].self, forKey: .stops) ?? []
        distanceKm = try container.decodeIfPresent(Int.self, forKey: .distanceKm)
        periodStartOdometer = try container.decodeIfPresent(Int.self, forKey: .periodStartOdometer)
        reportedDistanceKm = try container.decodeIfPresent(Double.self, forKey: .reportedDistanceKm)
        routeSummary = try container.decodeIfPresent(String.self, forKey: .routeSummary)
        requestNumbersSummary = try container.decodeIfPresent(String.self, forKey: .requestNumbersSummary)
        reportedPeriodStartOdometer = try container.decodeIfPresent(Int.self, forKey: .reportedPeriodStartOdometer)
        fuelDate = try container.decodeIfPresent(String.self, forKey: .fuelDate)
        fuelLiters = try container.decodeIfPresent(Double.self, forKey: .fuelLiters)
        fuelCostRub = try container.decodeIfPresent(Double.self, forKey: .fuelCostRub)
        sent = try container.decodeIfPresent(Bool.self, forKey: .sent) ?? false
    }
}

nonisolated struct RouteSettings: Codable, Hashable, Sendable {
    var warehouseAddress: String
    var homeAddress: String

    static let legacyOfficeAddress = "ул. Снежковой 17Б"
    static let officeAddress = "Алушта, ул. В. Хромых, 11"

    static let `default` = RouteSettings(
        warehouseAddress: RouteSettings.officeAddress,
        homeAddress: ""
    )

    var startAddress: String {
        address(for: .warehouse)
    }

    var endAddress: String {
        address(for: .warehouse)
    }

    init(warehouseAddress: String, homeAddress: String) {
        self.warehouseAddress = warehouseAddress
        self.homeAddress = homeAddress
    }

    func address(for endpoint: RouteEndpointKind) -> String {
        switch endpoint {
        case .warehouse:
            let trimmedWarehouse = warehouseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedWarehouse.isEmpty ? Self.officeAddress : trimmedWarehouse
        case .home:
            return homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum CodingKeys: String, CodingKey {
        case warehouseAddress
        case homeAddress
        case startAddress
        case endAddress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let oldStart = try container.decodeIfPresent(String.self, forKey: .startAddress)
        let oldEnd = try container.decodeIfPresent(String.self, forKey: .endAddress)
        let decodedWarehouse = try container.decodeIfPresent(String.self, forKey: .warehouseAddress)
        let decodedHome = try container.decodeIfPresent(String.self, forKey: .homeAddress)

        let warehouse = (decodedWarehouse ?? oldStart ?? Self.officeAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyHome = oldEnd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = decodedHome?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (legacyHome != nil && legacyHome != warehouse ? legacyHome ?? "" : "")

        self.warehouseAddress = warehouse.isEmpty ? Self.officeAddress : warehouse
        self.homeAddress = home
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(warehouseAddress, forKey: .warehouseAddress)
        try container.encode(homeAddress, forKey: .homeAddress)
        try container.encode(startAddress, forKey: .startAddress)
        try container.encode(endAddress, forKey: .endAddress)
    }
}

enum RouteEndpointKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case warehouse
    case home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warehouse:
            return "Склад"
        case .home:
            return "Дом"
        }
    }

    var systemImage: String {
        switch self {
        case .warehouse:
            return "shippingbox.fill"
        case .home:
            return "house.fill"
        }
    }
}

enum RouteEndpointRole: Hashable {
    case start
    case finish

    var title: String {
        switch self {
        case .start:
            return "Старт"
        case .finish:
            return "Финиш"
        }
    }
}

struct VirtualCardData: Codable, Hashable {
    var firstName: String
    var lastName: String
    var middleName: String
    var title: String
    var department: String
    var phone: String
    var email: String
    var organization: String

    static let `default` = VirtualCardData(
        firstName: "",
        lastName: "",
        middleName: "",
        title: "",
        department: "",
        phone: "",
        email: "",
        organization: ""
    )

    var fullName: String {
        [lastName, firstName, middleName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var vCard: String {
        let orgLine: String
        if !organization.isEmpty, !department.isEmpty {
            orgLine = "\(organization);\(department)"
        } else {
            orgLine = organization.isEmpty ? department : organization
        }

        return [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:\(lastName);\(firstName);\(middleName);;",
            "FN:\(fullName.isEmpty ? "Контакт" : fullName)",
            orgLine.isEmpty ? nil : "ORG:\(orgLine)",
            title.isEmpty ? nil : "TITLE:\(title)",
            phone.isEmpty ? nil : "TEL;TYPE=CELL:\(phone)",
            email.isEmpty ? nil : "EMAIL;TYPE=WORK:\(email)",
            "END:VCARD"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

nonisolated struct ClosedRequestInfoField: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        key
    }

    var key: String
    var value: String
}

nonisolated struct ClosedRequestRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        requestNumber
    }

    var requestNumber: String
    var shortDescription: String
    var status: String
    var rawStatus: String? = nil
    var engineerShift: String
    var workgroup: String
    var requestType: String
    var address: String
    var customer: String
    var contactPerson: String? = nil
    var contactPhone: String? = nil
    var engineerName: String
    var terminalModel: String
    var merchantTIN: String? = nil
    var posEquipment: String? = nil
    var dismantledEquipmentSerialNumber: String? = nil
    var engineerComment: String
    var closedAt: String
    var deadline: String? = nil
    var completedAt: String? = nil
    var closedInMulticardAt: String? = nil
    var additionalInformation: String? = nil
    var registeredAt: String? = nil
    var closureCode: String? = nil
    var resolution: String? = nil
    var terminalID: String
    var incomingNumber: String
    var infoFields: [ClosedRequestInfoField]
    var rawInfo: String
    var installedFiscalStorageSerialNumber: String? = nil
    var ofdTariffActivationCode: String? = nil
    var usedSIMCard: String? = nil
}

nonisolated enum ClosedRequestCompletionStatus: String, Sendable {
    case completed
    case refusal

    var title: String {
        switch self {
        case .completed:
            return "Выполнена"
        case .refusal:
            return "Отказ"
        }
    }
}

extension ClosedRequestRecord {
    var completionStatus: ClosedRequestCompletionStatus {
        let normalizedClosureCode = (closureCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))

        return normalizedClosureCode.hasPrefix("решено с выездом") ? .completed : .refusal
    }

    var isCompletedWithVisit: Bool {
        completionStatus == .completed
    }
}

nonisolated struct ClosedRequestsSnapshot: Codable, Hashable, Sendable {
    var fileName: String
    var importedAt: Date
    var records: [ClosedRequestRecord]
    var syncState: ClosedRequestsSyncState? = nil
}

nonisolated struct ClosedRequestsSyncCursor: Codable, Hashable, Sendable, Comparable {
    var updatedAt: String
    var sysID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.sysID < rhs.sysID
    }
}

nonisolated struct ClosedRequestsSyncRecordMetadata: Codable, Hashable, Sendable {
    var requestNumber: String
    var sysUpdatedAt: String
    var lastSeenAt: Date
    var excludedFromArchive: Bool? = nil
}

nonisolated struct ClosedRequestsSyncState: Codable, Hashable, Sendable {
    var userID: String
    var narrowWatermark: ClosedRequestsSyncCursor?
    var wideWatermark: ClosedRequestsSyncCursor?
    var wideConditionRevision: Int? = nil
    var lastNarrowSuccessAt: Date?
    var lastWideSuccessAt: Date?
    var isWideBaselineTrusted: Bool
    var requiresNarrowFullReconciliation: Bool
    var recordsBySysID: [String: ClosedRequestsSyncRecordMetadata]
}

nonisolated struct TimeReportEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        stableID
    }

    var activity: String
    var simpleOneRecordID: String? = nil
    var period: String
    var createdAt: Date
    var createdAtRaw: String
    var workDate: Date?
    var workDateRaw: String?
    var workMinutes: Int
    var travelMinutes: Int
    var overtimeMinutes: Int
    var notes: String
    var nonWorkCosts: String
    var isOvertime: Bool
    var executor: String

    var effectiveWorkDate: Date {
        workDate ?? createdAt
    }

    var stableID: String {
        [
            activity,
            String(Int(createdAt.timeIntervalSince1970)),
            executor
        ]
        .joined(separator: "|")
    }
}

nonisolated struct TimeReportSnapshot: Codable, Hashable, Sendable {
    var fileName: String
    var importedAt: Date
    var entries: [TimeReportEntry]
}

nonisolated struct TimeReportDaySummary: Hashable, Identifiable, Sendable {
    var id: String {
        dateKey
    }

    var dateKey: String
    var title: String
    var entries: [TimeReportEntry]
    var workMinutes: Int
    var travelMinutes: Int
    var overtimeMinutes: Int

    var totalMinutes: Int {
        workMinutes + travelMinutes
    }
}
