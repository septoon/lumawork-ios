import Foundation

nonisolated struct SimpleOneEmployeeAddress: Codable, Hashable, Identifiable, Sendable {
    var sysID: String
    var title: String
    var region: String
    var federalRegion: String

    var id: String { sysID }

    var subtitle: String {
        [region, federalRegion]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != title }
            .joined(separator: " · ")
    }
}

nonisolated struct SimpleOneEmployeeField: Codable, Hashable, Identifiable, Sendable {
    var systemName: String
    var title: String
    var value: String

    var id: String { systemName + "|" + title }
}

nonisolated struct SimpleOneEmployeeSection: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var fields: [SimpleOneEmployeeField]
}

nonisolated struct SimpleOneEmployee: Codable, Hashable, Identifiable, Sendable {
    var sysID: String
    var displayName: String
    var firstName: String
    var lastName: String
    var middleName: String
    var login: String
    var email: String
    var position: String
    var manager: String
    var company: String
    var department: String
    var phone: String
    var address: SimpleOneEmployeeAddress?
    var isActive: Bool?
    var isLocked: Bool?
    var updatedAt: String
    var detailSections: [SimpleOneEmployeeSection]

    var id: String { sysID }

    var fullName: String {
        let assembled = [lastName, firstName, middleName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return assembled.isEmpty ? displayName : assembled
    }

    var sortName: String {
        [fullName, displayName, login]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    var initials: String {
        let preferred = [firstName, lastName]
            .compactMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).first
            }
        let fallback = fullName
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
        return String((preferred.isEmpty ? fallback : preferred).prefix(2)).uppercased()
    }

    var roleText: String {
        [position, department]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Должность не указана"
    }
}
