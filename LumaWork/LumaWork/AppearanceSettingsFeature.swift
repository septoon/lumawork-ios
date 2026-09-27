import SwiftUI

enum AppBackgroundSettings {
    static let colorEnabledKey = "app-background-color-enabled"
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    static let storageKey = "app-appearance-mode"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "Система"
        case .light:
            "День"
        case .dark:
            "Ночь"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max.fill"
        case .dark:
            "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct AppearanceSettingsScreen: View {
    @AppStorage(AppAppearanceMode.storageKey) private var selectedModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppBackgroundSettings.colorEnabledKey) private var isBackgroundColorEnabled = true

    private var selectedMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: selectedModeRawValue) ?? .system
    }

    var body: some View {
        ZStack {
            AppTheme.background
            .ignoresSafeArea()

            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        AppearanceModeButton(
                            mode: mode,
                            isSelected: mode == selectedMode
                        ) {
                            AppHaptics.trigger(.expandCollapse)
                            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
                                selectedModeRawValue = mode.rawValue
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)

                HStack(spacing: 12) {
                    Label("Фоновый цвет", systemImage: "paintpalette")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Spacer(minLength: 12)

                    Toggle("Фоновый цвет", isOn: $isBackgroundColorEnabled)
                        .labelsHidden()
                        .tint(AppTheme.primaryTint)
                        .onChange(of: isBackgroundColorEnabled) { _, _ in
                            AppHaptics.trigger(.expandCollapse)
                        }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceModeButton: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? AppTheme.cardSurface : AnyShapeStyle(Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(
                                    isSelected ? AppTheme.border : AppTheme.mutedTint.opacity(0.16),
                                    lineWidth: isSelected ? 1 : 1.4
                                )
                        )
                        .shadow(
                            color: isSelected ? AppTheme.shadow.opacity(0.8) : .clear,
                            radius: 10,
                            x: 0,
                            y: 5
                        )

                    Image(systemName: mode.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isSelected ? AppTheme.ink : AppTheme.ink.opacity(0.72))
                }
                .frame(height: 72)

                Text(mode.title)
                    .font(.headline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.ink : AppTheme.mutedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
    }
}
