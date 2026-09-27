import SwiftUI

struct AppLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(AppTheme.primaryTint)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Идёт загрузка. \(title)")
    }
}

private struct AppLoadingOverlayModifier: ViewModifier {
    let isPresented: Bool
    let title: String

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)

            if isPresented {
                AppTheme.background
                    .ignoresSafeArea()

                AppLoadingView(title: title)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPresented)
    }
}

extension View {
    func appLoadingOverlay(
        isPresented: Bool,
        title: String
    ) -> some View {
        modifier(AppLoadingOverlayModifier(isPresented: isPresented, title: title))
    }
}

#Preview {
    AppScreen {
        Text("Контент")
    }
    .appLoadingOverlay(isPresented: true, title: "Загружаем данные")
}
