import SwiftUI

struct SelectableTextAccordion: View {
    let title: String
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    AppHaptics.trigger()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textSelection(.disabled)

                if isExpanded {
                    AppSelectableText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct ClosedRequestDayHeader: View {
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            if !caption.isEmpty {
                Text(caption.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

struct InfoFieldBlock: View {
    let field: ClosedRequestInfoField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.key)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AppSelectableText(
                text: field.value.isEmpty ? " " : field.value,
                textStyle: .subheadline,
                weight: .semibold
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActiveTableFieldBlock: View {
    let field: ClosedRequestInfoField

    private var value: String {
        let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Информация отсутствует" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.key)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AppSelectableText(
                text: value,
                textStyle: .subheadline,
                weight: .semibold
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LongTextCard: View {
    let title: String
    let text: String

    var body: some View {
        AppCard {
            AppSectionHeader(title: title)
            AppSelectableText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
