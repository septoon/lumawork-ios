import SwiftUI

struct RouteSettingsScreen: View {
    let routeStore: HomeRouteStore
    let sessionStore: AppSessionStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RouteSettings.default
    @State private var isSaving = false

    var body: some View {
        AppScreen {
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
            var profile = sessionStore.userProfile
            profile.routeWarehouseAddress = draft.warehouseAddress
            profile.routeHomeAddress = draft.homeAddress

            await sessionStore.saveProfile(profile)
            if sessionStore.errorMessage == nil {
                routeStore.updateRouteSettings(draft)
                dismiss()
            }
            isSaving = false
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
