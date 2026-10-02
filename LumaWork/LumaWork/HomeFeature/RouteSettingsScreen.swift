import SwiftUI

struct RouteSettingsScreen: View {
    let routeStore: HomeRouteStore
    let sessionStore: AppSessionStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RouteSettings.default
    @State private var isSaving = false

    var body: some View {
        AppScreen {
            AppSectionHeader(title: "Карты")

            AppCard {
                ForEach(RouteMapsProvider.allCases) { provider in
                    Button {
                        AppHaptics.trigger()
                        draft.mapsProvider = provider
                    } label: {
                        HStack(spacing: 12) {
                            Image(provider == .apple ? "AppleMapsIcon" : "YandexMapsIcon")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityHidden(true)
                            Text(provider.title)
                                .foregroundStyle(AppTheme.ink)
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.primaryTint)
                                .opacity(draft.mapsProvider == provider ? 1 : 0)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.mapsProvider == provider ? .isSelected : [])

                    if provider != RouteMapsProvider.allCases.last {
                        Divider()
                    }
                }

                Text(draft.mapsProvider == .apple
                    ? "Пробег рассчитывается автоматически и отправляется в отчёте за день."
                    : "Введите пробег дня вручную перед отправкой отчёта.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            AppSectionHeader(title: "Адреса")

            AppCard {
                RouteSettingsField(
                    title: "Склад",
                    systemName: RouteEndpointKind.warehouse.systemImage,
                    text: $draft.warehouseAddress
                )

                Divider()

                RouteSettingsField(
                    title: "Дом",
                    systemName: RouteEndpointKind.home.systemImage,
                    text: $draft.homeAddress
                )
            }
        }
        .navigationTitle("Маршрут")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModalConfirmButton(
                    action: {
                        AppHaptics.trigger()
                        save()
                    },
                    isLoading: isSaving,
                    accessibilityLabel: "Сохранить маршрут"
                )
            }
        }
        .task {
            draft = mergedSettings()
        }
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            let original = mergedSettings()
            if original.warehouseAddress != draft.warehouseAddress || original.homeAddress != draft.homeAddress {
                var profile = sessionStore.userProfile
                profile.routeWarehouseAddress = draft.warehouseAddress
                profile.routeHomeAddress = draft.homeAddress
                await sessionStore.saveProfile(profile)
                guard sessionStore.errorMessage == nil else { return }
            }
            routeStore.updateRouteSettings(draft)
            dismiss()
        }
    }

    private func mergedSettings() -> RouteSettings {
        var settings = routeStore.routeSettings
        let profile = sessionStore.userProfile

        if let warehouse = UserProfileData.clean(profile.routeWarehouseAddress) {
            settings.warehouseAddress = warehouse
        }
        if let home = UserProfileData.clean(profile.routeHomeAddress) {
            settings.homeAddress = home
        }

        return settings
    }
}

private struct RouteSettingsField: View {
    let title: String
    let systemName: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            TextField(title, text: $text)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.secondaryTint.opacity(0.3), lineWidth: 1)
                )
        }
    }
}
