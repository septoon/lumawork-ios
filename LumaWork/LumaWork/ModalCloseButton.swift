import SwiftUI

struct ModalCloseButton: View {
    let action: () -> Void
    var tint: Color = AppTheme.primaryTint

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
            .tint(tint)
            .accessibilityLabel("Закрыть")
    }
}

struct ModalConfirmButton: View {
    let action: () -> Void
    var isDisabled = false
    var isLoading = false
    var tint: Color = Color(red: 0.04, green: 0.52, blue: 1.0)
    var accessibilityLabel = "Сохранить"

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Label(accessibilityLabel, systemImage: "checkmark")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(tint)
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}
