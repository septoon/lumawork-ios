import SwiftUI

struct ActiveRequestHeaderMetric: View {
    var icon: String?
    var prefix: String?
    let title: String
    var isLinkLike = false
    var action: (() -> Void)?
    var longPressAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActiveRequestStyle.mutedText)
                    .frame(width: 21)
            } else if let prefix {
                Text(prefix)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ActiveRequestStyle.mutedText)
                    .frame(width: 31, alignment: .leading)
            }

            AppSelectableText(
                text: title,
                textStyle: .body,
                weight: .medium,
                pointSize: 19,
                design: .rounded,
                color: isLinkLike ? ActiveRequestStyle.linkText : ActiveRequestStyle.primaryText,
                isUnderlined: isLinkLike,
                onTap: action,
                onLongPress: longPressAction
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(accessibilityHint)
        }
    }

    private var accessibilityHint: String {
        if longPressAction != nil {
            return "Коснитесь, чтобы скопировать. Удерживайте, чтобы открыть складскую заявку."
        }
        return action == nil ? "" : "Коснитесь, чтобы скопировать."
    }
}

struct ActiveRequestDisclosureCard<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: () -> Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 15 : 0) {
            Button {
                AppHaptics.trigger()
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(ActiveRequestStyle.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(ActiveRequestStyle.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, isExpanded ? 16 : 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ActiveRequestStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ActiveRequestStyle.cardStroke, lineWidth: 1)
        )
        .shadow(color: ActiveRequestStyle.cardShadow, radius: 5, x: 0, y: 2)
    }
}

struct ActiveRequestValueBlock: View {
    let title: String?
    let value: String
    var isLinkLike = false
    var action: (() -> Void)?
    var longPressAction: (() -> Void)?
    var accessibilityHint = ""

    var body: some View {
        valueStack
    }

    private var valueStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                AppSelectableText(
                    text: title,
                    textStyle: .body,
                    weight: .medium,
                    pointSize: 17,
                    design: .rounded,
                    color: ActiveRequestStyle.mutedText
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppSelectableText(
                text: value,
                textStyle: .body,
                weight: .medium,
                pointSize: 18,
                design: .rounded,
                color: isLinkLike ? ActiveRequestStyle.linkText : ActiveRequestStyle.primaryText,
                textAlignment: .left,
                isUnderlined: isLinkLike,
                onTap: action,
                onLongPress: longPressAction
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(accessibilityHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ActiveRequestStyle {
    static let background = AppTheme.background
    static let primaryText = AppTheme.ink
    static let mutedText = AppTheme.mutedTint
    static let linkText = AppTheme.primaryTint
    static let cardFill = AppTheme.performancePanelFill
    static let cardStroke = AppTheme.primaryTint.opacity(0.16)
    static let cardShadow = AppTheme.shadow.opacity(0.45)
}
