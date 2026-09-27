import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ProfileStore {
    private let storageKey = "virtual-card-data"

    var card = VirtualCardData.default

    init() {
        load()
    }

    func load() {
        guard let raw = UserDefaults.standard.data(forKey: storageKey),
              let card = try? JSONDecoder().decode(VirtualCardData.self, from: raw) else {
            return
        }
        self.card = card
    }

    func save() {
        guard let data = try? JSONEncoder().encode(card) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

struct ProfileScreen: View {
    let profile: UserProfileData
    let avatarUrl: String?
    @Bindable var vehicleStore: VehicleStore
    @Bindable var workDocumentsStore: WorkDocumentsStore
    let closedRequestsStore: ClosedRequestsStore

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProfilePreferenceKeys.vehicleSectionVisible) private var isVehicleSectionVisible = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ProfileAvatar(size: 68, avatarUrl: avatarUrl)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName ?? "Ваш профиль")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)

                        if let jobTitle = clean(profile.jobTitle) {
                            Text(jobTitle)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedTint)
                        } else if displayName == nil {
                            Text("Добавьте имя и контакты в настройках")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                ProfileCompletedWorkSection(
                    statistics: ProfileCompletedWorkStatistics(records: closedRequestsStore.records),
                    isLoading: closedRequestsStore.isLoadingSnapshot && closedRequestsStore.records.isEmpty,
                    hasArchive: closedRequestsStore.snapshot != nil,
                    onCategoryTap: handleWorkCategoryTap
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }

            Section("Контакты") {
                if contactInfo.isEmpty {
                    Label("Телефон и почта пока не добавлены", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(contactInfo, id: \.title) { item in
                        ProfileInfoRow(
                            title: item.title,
                            value: item.value,
                            systemImage: item.systemImage
                        )
                    }
                }
            }

            if let city = clean(profile.city) {
                Section("Работа") {
                    ProfileInfoRow(
                        title: "Город",
                        value: city,
                        systemImage: "building.2"
                    )
                }
            }

            if isVehicleSectionVisible, !vehicleInfo.isEmpty {
                Section {
                    ForEach(vehicleInfo, id: \.title) { item in
                        Button {
                            AppHaptics.trigger()
                            AppClipboard.copy(item.value)
                        } label: {
                            ProfileInfoRow(
                                title: item.title,
                                value: item.value,
                                systemImage: item.systemImage
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Копирует значение")
                    }
                } header: {
                    Text("Автомобиль")
                } footer: {
                    Text("Нажмите строку, чтобы скопировать значение.")
                }
            }

            Section("Документы для работы") {
                NavigationLink {
                    WorkDocumentsScreen(store: workDocumentsStore, canManage: false)
                } label: {
                    LabeledContent {
                        Text(workDocumentsStore.documents.isEmpty ? "Нет документов" : "\(workDocumentsStore.documents.count)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Открыть документы", systemImage: "folder.fill")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton {
                    dismiss()
                }
            }
        }
        .task {
            await vehicleStore.load(showsNetworkBanner: false)
            await workDocumentsStore.load()
        }
    }

    private func handleWorkCategoryTap(_ category: ProfileWorkCategory) {
        // The typed category can become a route in this sheet's NavigationStack.
        // Detail navigation is intentionally deferred.
        AppHaptics.trigger()
    }

    private var displayName: String? {
        let value = [profile.lastName, profile.firstName, profile.middleName]
            .compactMap(clean)
            .joined(separator: " ")
        return UserProfileData.clean(value)
    }

    private var contactInfo: [ProfileInfoItem] {
        return compactInfo([
            ProfileInfoCandidate(title: "Телефон", value: profile.personalPhone, systemImage: "phone"),
            ProfileInfoCandidate(title: "Почта", value: profile.workEmail, systemImage: "envelope")
        ])
    }

    private var vehicleInfo: [ProfileInfoItem] {
        if let vehicle = vehicleStore.vehicles.first(where: \.isPrimary)
            ?? vehicleStore.selectedVehicle
            ?? vehicleStore.vehicles.first {
            let modelName = [vehicle.make, vehicle.model]
                .compactMap(UserProfileData.clean)
                .joined(separator: " ")
            return compactInfo([
                ProfileInfoCandidate(title: "Модель", value: UserProfileData.clean(modelName) ?? vehicle.customName, systemImage: "car"),
                ProfileInfoCandidate(title: "Поколение", value: vehicle.generation, systemImage: "square.stack.3d.up"),
                ProfileInfoCandidate(title: "Год", value: vehicle.year.map(String.init), systemImage: "calendar"),
                ProfileInfoCandidate(title: "Кузов", value: vehicle.bodyType, systemImage: "car.side"),
                ProfileInfoCandidate(title: "Госномер", value: vehicle.licensePlate, systemImage: "rectangle"),
                ProfileInfoCandidate(title: "VIN", value: vehicle.vin, systemImage: "number"),
                ProfileInfoCandidate(title: "СТС", value: vehicle.sts, systemImage: "doc.text"),
                ProfileInfoCandidate(title: "ПТС", value: vehicle.pts, systemImage: "doc.text"),
                ProfileInfoCandidate(title: "Цвет", value: vehicle.colorName, systemImage: "paintpalette"),
                ProfileInfoCandidate(title: "Объем двигателя", value: formatted(vehicle.engineVolumeCm3.map(String.init), suffix: "см³"), systemImage: "engine.combustion"),
                ProfileInfoCandidate(title: "Мощность", value: formatted(vehicle.enginePowerHp.map(String.init), suffix: "л.с."), systemImage: "bolt"),
                ProfileInfoCandidate(title: "Пробег", value: formatted(vehicle.currentMileageKm.map(String.init), suffix: "км"), systemImage: "road.lanes")
            ])
        }

        return compactInfo([
            ProfileInfoCandidate(title: "Модель", value: profile.vehicleModel, systemImage: "car"),
            ProfileInfoCandidate(title: "Госномер", value: profile.vehiclePlate, systemImage: "rectangle"),
            ProfileInfoCandidate(title: "VIN", value: profile.vehicleVin, systemImage: "number"),
            ProfileInfoCandidate(title: "СТС", value: profile.vehicleSts, systemImage: "doc.text"),
            ProfileInfoCandidate(title: "ПТС", value: profile.vehiclePts, systemImage: "doc.text"),
            ProfileInfoCandidate(title: "Цвет", value: profile.vehicleColor, systemImage: "paintpalette"),
            ProfileInfoCandidate(title: "Объем двигателя", value: formatted(profile.engineVolumeCm3, suffix: "см³"), systemImage: "engine.combustion"),
            ProfileInfoCandidate(title: "Мощность", value: formatted(profile.enginePowerHp, suffix: "л.с."), systemImage: "bolt"),
            ProfileInfoCandidate(title: "Начальный пробег", value: formatted(profile.initialMileageKm, suffix: "км"), systemImage: "road.lanes")
        ])
    }

    private func compactInfo(_ items: [ProfileInfoCandidate]) -> [ProfileInfoItem] {
        items.compactMap { item in
            guard let value = clean(item.value) else { return nil }
            return ProfileInfoItem(title: item.title, value: value, systemImage: item.systemImage)
        }
    }

    private func formatted(_ value: String?, suffix: String) -> String? {
        clean(value).map { "\($0) \(suffix)" }
    }

    private func clean(_ value: String?) -> String? {
        UserProfileData.clean(value)
    }
}

private enum ProfilePreferenceKeys {
    static let vehicleSectionVisible = "profile.vehicle-section-visible"
}

private struct ProfileInfoItem {
    let title: String
    let value: String
    let systemImage: String
}

private struct ProfileInfoCandidate {
    let title: String
    let value: String?
    let systemImage: String
}

private struct ProfileInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct ProfileAvatar: View {
    let size: CGFloat
    var avatarUrl: String? = nil

    var body: some View {
        ZStack {
            placeholder

            if let avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(AppTheme.primaryTint.opacity(0.14))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(AppTheme.primaryTint)
            )
    }
}

struct ProfileSettingsScreen: View {
    let sessionStore: AppSessionStore
    @Bindable var vehicleStore: VehicleStore
    @Bindable var workDocumentsStore: WorkDocumentsStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft = UserProfileData.empty
    @State private var vehicleDraft = VehicleDraft()
    @State private var editingVehicleID: String?
    @State private var isVehicleSectionVisible = true
    @AppStorage(ProfilePreferenceKeys.vehicleSectionVisible) private var storedVehicleSectionVisible = true

    var body: some View {
        AppScreen {
            AppSectionHeader(
                title: "О вас",
                caption: "Все поля необязательные"
            )

            AppCard {
                ProfileSettingsField(
                    title: "Фамилия",
                    placeholder: "Фамилия",
                    text: textBinding(\.lastName),
                    kind: .familyName
                )
                ProfileSettingsField(
                    title: "Имя",
                    placeholder: "Имя",
                    text: textBinding(\.firstName),
                    kind: .givenName
                )
                ProfileSettingsField(
                    title: "Отчество",
                    placeholder: "Отчество",
                    text: textBinding(\.middleName),
                    kind: .name
                )
                ProfileSettingsField(
                    title: "Должность",
                    placeholder: "Старший инженер",
                    text: textBinding(\.jobTitle),
                    kind: .jobTitle
                )
                ProfileSettingsField(
                    title: "Город",
                    placeholder: "Город работы",
                    text: textBinding(\.city),
                    kind: .address
                )
            }

            AppSectionHeader(
                title: "Документы для работы",
                caption: "Справки, договоры, положения и другие файлы"
            )

            NavigationLink {
                WorkDocumentsScreen(store: workDocumentsStore, canManage: true)
            } label: {
                AppCard {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Управление документами")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Text(workDocumentsStore.documents.isEmpty ? "Документы не прикреплены" : "Прикреплено: \(workDocumentsStore.documents.count)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }
            }
            .buttonStyle(.plain)

            AppSectionHeader(
                title: "Контакты",
                caption: "Для связи и автозаполнения"
            )

            AppCard {
                ProfileSettingsField(
                    title: "Телефон",
                    placeholder: "+7 978 000-00-00",
                    text: textBinding(\.personalPhone),
                    kind: .phone
                )
                ProfileSettingsField(
                    title: "Почта",
                    placeholder: "name@company.ru",
                    text: textBinding(\.workEmail),
                    kind: .email,
                    errorText: isEmailValid ? nil : "Проверьте формат почты"
                )
            }

            AppSectionHeader(
                title: "Основной автомобиль",
                caption: "Синхронизируется с экраном «Авто»"
            )

            AppCard {
                Toggle(isOn: $isVehicleSectionVisible.animation(.easeInOut(duration: 0.2))) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Показывать в профиле")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("Скрытие не удаляет сохраненные данные")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }
                .tint(AppTheme.primaryTint)

                if isVehicleSectionVisible {
                    Divider()

                    ProfileSettingsField(title: "Марка", placeholder: "Марка автомобиля", text: vehicleTextBinding(\.make))
                    ProfileSettingsField(title: "Модель", placeholder: "Модель автомобиля", text: vehicleTextBinding(\.model))
                    ProfileSettingsField(title: "Поколение", placeholder: "Например: II", text: vehicleTextBinding(\.generation))
                    ProfileSettingsField(title: "Год выпуска", placeholder: "Например: 2020", text: vehicleTextBinding(\.year), kind: .number)
                    ProfileSettingsField(title: "Тип кузова", placeholder: "Например: кроссовер", text: vehicleTextBinding(\.bodyType))
                    ProfileSettingsField(title: "Госномер", placeholder: "А123ВС 00", text: vehicleTextBinding(\.licensePlate), kind: .identifier)
                    ProfileSettingsField(title: "VIN", placeholder: "17 символов VIN", text: vehicleTextBinding(\.vin), kind: .identifier)
                    ProfileSettingsField(title: "СТС", placeholder: "00 00 000000", text: vehicleTextBinding(\.sts), kind: .identifier)
                    ProfileSettingsField(title: "ПТС", placeholder: "00 АА 000000", text: vehicleTextBinding(\.pts), kind: .identifier)
                    ProfileSettingsField(title: "Цвет", placeholder: "Цвет автомобиля", text: vehicleTextBinding(\.colorName))
                    ProfileSettingsField(title: "Объем двигателя, см³", placeholder: "Например: 1600", text: vehicleTextBinding(\.engineVolumeCm3), kind: .number)
                    ProfileSettingsField(title: "Мощность, л.с.", placeholder: "Например: 120", text: vehicleTextBinding(\.enginePowerHp), kind: .number)
                    ProfileSettingsField(title: "Текущий пробег, км", placeholder: "Например: 100000", text: vehicleTextBinding(\.currentMileageKm), kind: .number)
                    ProfileSettingsField(title: "Название", placeholder: "Например: рабочий автомобиль", text: vehicleTextBinding(\.customName))
                }
            }

            if let errorMessage = vehicleStore.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }
        }
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        AppHaptics.trigger()
                        Task {
                            await save()
                        }
                    },
                    isDisabled: !isEmailValid,
                    isLoading: sessionStore.isLoading || vehicleStore.isSaving,
                    accessibilityLabel: "Сохранить профиль"
                )
            }
        }
        .task {
            draft = sessionStore.userProfile
            await workDocumentsStore.load()
            await vehicleStore.load(showsNetworkBanner: false)
            if let vehicle = vehicleStore.vehicles.first(where: \.isPrimary)
                ?? vehicleStore.selectedVehicle
                ?? vehicleStore.vehicles.first {
                vehicleDraft = VehicleDraft(vehicle: vehicle)
                editingVehicleID = vehicle.id
            } else {
                vehicleDraft = VehicleDraft(profile: draft)
                editingVehicleID = nil
            }
            isVehicleSectionVisible = storedVehicleSectionVisible
        }
    }

    private func textBinding(_ keyPath: WritableKeyPath<UserProfileData, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func vehicleTextBinding(_ keyPath: WritableKeyPath<VehicleDraft, String>) -> Binding<String> {
        Binding(
            get: { vehicleDraft[keyPath: keyPath] },
            set: { vehicleDraft[keyPath: keyPath] = $0 }
        )
    }

    private var isEmailValid: Bool {
        guard let email = UserProfileData.clean(draft.workEmail) else { return true }
        return email.range(
            of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
            options: .regularExpression
        ) != nil
    }

    private func normalizeContacts() {
        draft.personalPhone = UserProfileData.clean(draft.personalPhone)
        draft.workEmail = UserProfileData.clean(draft.workEmail)
    }

    private func save() async {
        normalizeContacts()
        synchronizeLegacyProfileFields()
        await sessionStore.saveProfile(draft)
        guard sessionStore.errorMessage == nil else { return }

        let vehicleSaved = await vehicleStore.savePrimaryVehicle(
            vehicleDraft,
            existingVehicleID: editingVehicleID
        )
        guard vehicleSaved else { return }

        storedVehicleSectionVisible = isVehicleSectionVisible
        dismiss()
    }

    private func synchronizeLegacyProfileFields() {
        let generatedName = [vehicleDraft.make, vehicleDraft.model, vehicleDraft.generation]
            .compactMap(UserProfileData.clean)
            .joined(separator: " ")
        draft.vehicleModel = UserProfileData.clean(vehicleDraft.customName)
            ?? UserProfileData.clean(generatedName)
        draft.vehiclePlate = UserProfileData.clean(vehicleDraft.licensePlate)
        draft.vehicleVin = UserProfileData.clean(vehicleDraft.vin)
        draft.vehicleSts = UserProfileData.clean(vehicleDraft.sts)
        draft.vehiclePts = UserProfileData.clean(vehicleDraft.pts)
        draft.vehicleColor = UserProfileData.clean(vehicleDraft.colorName)
        draft.engineVolumeCm3 = UserProfileData.clean(vehicleDraft.engineVolumeCm3)
        draft.enginePowerHp = UserProfileData.clean(vehicleDraft.enginePowerHp)
        draft.initialMileageKm = UserProfileData.clean(vehicleDraft.currentMileageKm)
    }
}

private struct ProfileSettingsField: View {
    let title: String
    var placeholder: String? = nil
    @Binding var text: String
    var kind: ProfileSettingsFieldKind = .text
    var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            TextField(
                title,
                text: $text,
                prompt: Text(placeholder ?? title).foregroundStyle(AppTheme.mutedTint.opacity(0.6))
            )
            .textFieldStyle(.plain)
            .keyboardType(kind.keyboardType)
            .textContentType(kind.contentType)
            .textInputAutocapitalization(kind.capitalization)
            .autocorrectionDisabled(kind.disablesAutocorrection)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(AppTheme.softFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(errorText == nil ? AppTheme.border : AppTheme.dangerTint, lineWidth: 1)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.dangerTint)
            }
        }
    }
}

private enum ProfileSettingsFieldKind {
    case text
    case name
    case givenName
    case familyName
    case jobTitle
    case phone
    case email
    case address
    case identifier
    case number

    var keyboardType: UIKeyboardType {
        switch self {
        case .phone:
            return .phonePad
        case .email:
            return .emailAddress
        case .identifier:
            return .asciiCapable
        case .number:
            return .numberPad
        default:
            return .default
        }
    }

    var contentType: UITextContentType? {
        switch self {
        case .givenName:
            return .givenName
        case .familyName:
            return .familyName
        case .jobTitle:
            return .jobTitle
        case .address:
            return .addressCity
        case .phone:
            return .telephoneNumber
        case .email:
            return .emailAddress
        default:
            return nil
        }
    }

    var capitalization: TextInputAutocapitalization? {
        switch self {
        case .email, .phone, .number:
            return .never
        case .identifier:
            return .characters
        case .name, .givenName, .familyName, .jobTitle, .address, .text:
            return .words
        }
    }

    var disablesAutocorrection: Bool {
        switch self {
        case .phone, .email, .identifier, .number:
            return true
        default:
            return false
        }
    }
}

struct VirtualCardScreen: View {
    let profileStore: ProfileStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft = VirtualCardData.default

    var body: some View {
        AppScreen {
            AppCard {
                VStack(spacing: 16) {
                    if let image = QRCodeBuilder.image(for: draft.vCard) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding()
                            .background(AppTheme.qrSurface, in: RoundedRectangle(cornerRadius: 24))
                    } else {
                        ContentUnavailableView("QR-код недоступен", systemImage: "qrcode")
                    }

                    Text(draft.fullName.isEmpty ? "Контакт" : draft.fullName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("Отсканируйте код, чтобы добавить контакт.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedTint)
                }
                .frame(maxWidth: .infinity)
            }

            AppCard {
                AppSectionHeader(title: "Контакт")

                Group {
                    TextField("Фамилия", text: $draft.lastName)
                        .textContentType(.familyName)
                    TextField("Имя", text: $draft.firstName)
                        .textContentType(.givenName)
                    TextField("Отчество", text: $draft.middleName)
                    TextField("Организация", text: $draft.organization)
                        .textContentType(.organizationName)
                    TextField("Подразделение", text: $draft.department)
                    TextField("Должность", text: $draft.title)
                        .textContentType(.jobTitle)
                    TextField("Телефон", text: $draft.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    TextField("Email", text: $draft.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                }
                .textFieldStyle(.roundedBorder)
            }
        }
        .navigationTitle("Визитка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        AppHaptics.trigger()
                        profileStore.card = draft
                        profileStore.save()
                        dismiss()
                    },
                    accessibilityLabel: "Сохранить визитку"
                )
            }
        }
        .task {
            draft = profileStore.card
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
