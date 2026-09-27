import Foundation
import Observation
import SwiftUI

struct AdminGsmProject: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var budgetCode: String
    var isActive: Bool
    var sortOrder: Int
}

@MainActor
private struct AdminGsmProjectsAPI {
    private struct Response: Decodable {
        let projects: [AdminGsmProject]
    }

    private let baseURL: URL
    private let http = HTTPClient()

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    func fetch(token: String) async throws -> [AdminGsmProject] {
        try decode(try await http.request(url, authToken: token).json).projects
    }

    func update(_ projects: [AdminGsmProject], token: String) async throws -> [AdminGsmProject] {
        let payload: [[String: Any]] = projects.enumerated().map { index, project in
            [
                "id": project.id,
                "name": project.name,
                "budgetCode": project.budgetCode,
                "isActive": project.isActive,
                "sortOrder": index
            ]
        }
        return try decode(try await http.request(
            url,
            method: "PUT",
            body: ["projects": payload],
            authToken: token
        ).json).projects
    }

    private var url: URL {
        baseURL.appendingPathComponent("api/v2/admin/gsm-projects")
    }

    private func decode(_ json: Any?) throws -> Response {
        guard let json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        return try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
@Observable
private final class AdminGsmProjectsStore {
    private let token: String?
    private let api = AdminGsmProjectsAPI(config: AppConfig())
    private var savedProjects: [AdminGsmProject] = []

    var projects: [AdminGsmProject] = []
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var notice: String?

    init(token: String?) {
        self.token = token
    }

    var isDirty: Bool { projects != savedProjects }

    func load() async {
        guard projects.isEmpty, !isLoading else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await api.fetch(token: token))
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func add() {
        projects.append(AdminGsmProject(
            id: UUID().uuidString,
            name: "",
            budgetCode: "",
            isActive: true,
            sortOrder: projects.count
        ))
    }

    func update(_ project: AdminGsmProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        notice = nil
    }

    func save() async {
        guard !isSaving, isDirty else { return }
        guard projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.budgetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            errorMessage = "Заполните название и код бюджета для каждого проекта."
            return
        }
        guard let token, !token.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            apply(try await api.update(projects, token: token))
            notice = "Справочник проектов сохранён."
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func apply(_ value: [AdminGsmProject]) {
        projects = value
        savedProjects = value
        errorMessage = nil
    }
}

struct AdminGsmProjectsCard: View {
    @State private var store: AdminGsmProjectsStore
    let canEdit: Bool

    init(token: String?, canEdit: Bool) {
        _store = State(initialValue: AdminGsmProjectsStore(token: token))
        self.canEdit = canEdit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(
                title: "Проекты и коды бюджета",
                caption: "Единый серверный справочник для POS и АРМ"
            )

            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            ForEach(store.projects) { project in
                projectRow(project)
            }

            if store.isLoading {
                AppLoadingView(title: "Загружаю проекты")
            }

            if canEdit {
                HStack(spacing: 12) {
                    Button("Добавить", systemImage: "plus") {
                        store.add()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await store.save() }
                    } label: {
                        if store.isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Сохранить").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isDirty || store.isSaving)
                }
            }
        }
        .task { await store.load() }
    }

    private func projectRow(_ project: AdminGsmProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Проект", text: binding(project, \.name))
                .font(.subheadline.weight(.semibold))
                .disabled(!canEdit)
            TextField("Код бюджета", text: binding(project, \.budgetCode))
                .font(.caption.monospaced())
                .textInputAutocapitalization(.characters)
                .disabled(!canEdit)
            Toggle("Доступен для выбора", isOn: binding(project, \.isActive))
                .font(.caption)
                .disabled(!canEdit)
        }
        .padding(12)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func binding<Value>(_ project: AdminGsmProject, _ keyPath: WritableKeyPath<AdminGsmProject, Value>) -> Binding<Value> {
        Binding(
            get: { store.projects.first(where: { $0.id == project.id })?[keyPath: keyPath] ?? project[keyPath: keyPath] },
            set: { value in
                var updated = store.projects.first(where: { $0.id == project.id }) ?? project
                updated[keyPath: keyPath] = value
                store.update(updated)
            }
        )
    }
}
