import Foundation
import SwiftUI

struct CompanyLookupSelection: Identifiable {
    let inn: String
    var id: String { inn }

    init?(inn rawValue: String) {
        let normalized = rawValue.filter(\.isNumber)
        guard normalized.count == 10 || normalized.count == 12 else { return nil }
        inn = normalized
    }
}

struct CompanyLookupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: CompanyLookupSelection
    let authToken: String?

    @State private var state: LoadState = .loading
    @State private var retryID = 0

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    CompanyLookupSkeleton()
                case .loaded(let company):
                    CompanyLookupContent(company: company)
                case .failed(let message):
                    CompanyLookupErrorView(message: message) {
                        retryID += 1
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.background)
            .navigationTitle("Данные по ИНН")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: "\(selection.inn)|\(retryID)") {
            await loadCompany()
        }
    }

    @MainActor
    private func loadCompany() async {
        state = .loading
        guard let authToken, !authToken.isEmpty else {
            state = .failed("Для загрузки данных нужно войти в LumaWork.")
            return
        }

        do {
            let company = try await CompanyLookupAPI().company(inn: selection.inn, authToken: authToken)
            guard !Task.isCancelled else { return }
            state = .loaded(company)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Не удалось получить данные организации.")
        }
    }
}

private enum LoadState {
    case loading
    case loaded(CompanyLookupCompany)
    case failed(String)
}

private struct CompanyLookupResponse: Decodable {
    let company: CompanyLookupCompany
}

private struct CompanyLookupErrorResponse: Decodable {
    let message: String?
}

private struct CompanyLookupCompany: Decodable {
    let name: String
    let fullName: String?
    let inn: String
    let kpp: String?
    let ogrn: String?
    let status: String?
    let legalForm: String?
    let directorName: String?
    let directorPost: String?
    let address: String?
    let okved: String?
    let okvedName: String?
    let registrationDate: String?
}

private struct CompanyLookupAPI {
    private let baseURL: URL
    private let session: URLSession

    init(config: AppConfig = AppConfig(), session: URLSession = .shared) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
        self.session = session
    }

    func company(inn: String, authToken: String) async throws -> CompanyLookupCompany {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v2")
                .appendingPathComponent("reference")
                .appendingPathComponent("companies")
                .appendingPathComponent(inn)
        )
        request.timeoutInterval = 12
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        AppBuildIdentity.apply(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let serverMessage = try? JSONDecoder().decode(CompanyLookupErrorResponse.self, from: data).message
            throw AppServiceError.message(serverMessage ?? "Не удалось получить данные организации.")
        }

        do {
            return try JSONDecoder().decode(CompanyLookupResponse.self, from: data).company
        } catch {
            throw AppServiceError.message("Сервер вернул некорректные данные организации.")
        }
    }
}

private struct CompanyLookupSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AppCard {
                    skeletonLine(width: 210, height: 22)
                    skeletonLine(width: 132, height: 16)
                    skeletonLine(width: 94, height: 24)
                }

                AppCard {
                    ForEach(0 ..< 5, id: \.self) { index in
                        HStack(alignment: .top, spacing: 16) {
                            skeletonLine(width: index.isMultiple(of: 2) ? 76 : 104, height: 14)
                            Spacer(minLength: 12)
                            skeletonLine(width: index.isMultiple(of: 2) ? 148 : 118, height: 15)
                        }
                    }
                }

                AppCard {
                    skeletonLine(width: 88, height: 14)
                    skeletonLine(width: nil, height: 16)
                    skeletonLine(width: 246, height: 16)
                }
            }
            .padding(14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загрузка данных организации")
        .onAppear {
            guard !reduceMotion else { return }
            shimmerPhase = -1
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.6
            }
        }
    }

    private func skeletonLine(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(height / 2, 8), style: .continuous)
            .fill(AppTheme.mutedTint.opacity(0.16))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.42), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(proxy.size.width * 0.7, 44))
                        .offset(x: proxy.size.width * shimmerPhase)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: min(height / 2, 8), style: .continuous))
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: height)
    }
}

private struct CompanyLookupContent: View {
    let company: CompanyLookupCompany

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AppCard {
                    Text(company.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let fullName = meaningful(company.fullName), fullName != company.name {
                        Text(fullName)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedTint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let status = meaningful(company.status) {
                        Label(statusTitle(status), systemImage: status.uppercased() == "ACTIVE" ? "checkmark.seal.fill" : "info.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.uppercased() == "ACTIVE" ? AppTheme.primaryTint : AppTheme.secondaryTint)
                    }
                }

                AppCard {
                    AppSectionHeader(title: "Реквизиты")
                    AppStatRow(title: "ИНН", value: company.inn)
                    if let kpp = meaningful(company.kpp) { AppStatRow(title: "КПП", value: kpp) }
                    if let ogrn = meaningful(company.ogrn) { AppStatRow(title: "ОГРН", value: ogrn) }
                    if let legalForm = meaningful(company.legalForm) { AppStatRow(title: "Форма", value: legalForm) }
                    if let date = registrationDateText { AppStatRow(title: "Регистрация", value: date) }
                }

                if directorText != nil || meaningful(company.address) != nil {
                    AppCard {
                        AppSectionHeader(title: "Организация")
                        if let directorText { AppStatRow(title: "Руководитель", value: directorText) }
                        if let address = meaningful(company.address) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Юридический адрес")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedTint)
                                AppSelectableText(text: address, textStyle: .subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if meaningful(company.okved) != nil || meaningful(company.okvedName) != nil {
                    AppCard {
                        AppSectionHeader(title: "Основной ОКВЭД")
                        if let okved = meaningful(company.okved) { AppStatRow(title: "Код", value: okved) }
                        if let okvedName = meaningful(company.okvedName) {
                            AppSelectableText(text: okvedName, textStyle: .subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var directorText: String? {
        let values = [meaningful(company.directorName), meaningful(company.directorPost)].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var registrationDateText: String? {
        guard let rawValue = meaningful(company.registrationDate),
              let date = ISO8601DateFormatter().date(from: rawValue) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).year().locale(AppLocale.russian))
    }

    private func statusTitle(_ status: String) -> String {
        switch status.uppercased() {
        case "ACTIVE": "Действующая"
        case "LIQUIDATING": "Ликвидируется"
        case "LIQUIDATED": "Ликвидирована"
        case "BANKRUPT": "Банкротство"
        case "REORGANIZING": "Реорганизация"
        default: status
        }
    }
}

private struct CompanyLookupErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Данные недоступны", systemImage: "building.2.crop.circle")
        } description: {
            Text(message)
        } actions: {
            Button("Повторить", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

private func meaningful(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? nil : normalized
}
