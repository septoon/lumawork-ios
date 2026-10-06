import SwiftUI
import UIKit

nonisolated enum AppLocale {
    static let russian = Locale(identifier: "ru_RU")
}

private struct AppOfflineModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appIsOfflineMode: Bool {
        get { self[AppOfflineModeEnvironmentKey.self] }
        set { self[AppOfflineModeEnvironmentKey.self] = newValue }
    }
}

enum AppOfflineWarningPolicy {
    static func shouldDisplay(_ text: String, isOfflineMode: Bool) -> Bool {
        AppErrorPresentation.isDomainMessage(text)
    }
}

struct AppBackgroundView: View {
    @AppStorage(AppBackgroundSettings.colorEnabledKey) private var isBackgroundColorEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(backgroundStyle)
            .ignoresSafeArea(.container)
    }

    private var backgroundStyle: AnyShapeStyle {
        if isBackgroundColorEnabled {
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color("AppBackgroundTop"),
                    Color("AppBackgroundMiddle"),
                    Color("AppBackgroundBottom")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            AnyShapeStyle(colorScheme == .dark ? Color.black : Color.white)
        }
    }
}

@MainActor
func appDismissTransientMessage(
    _ value: String?,
    delayNanoseconds: UInt64 = 2_500_000_000,
    clearIfCurrent: @escaping @MainActor (String) -> Void
) async {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }

    do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
    } catch {
        return
    }

    guard !Task.isCancelled else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
        clearIfCurrent(value)
    }
}

enum AppTheme {
    enum GlassMode {
        case highQualityGlass
        case performanceGlass
    }

    static let glassMode: GlassMode = .performanceGlass

    static let ink = Color("AppInk")
    static let primaryTint = Color("AppPrimaryTint")
    static let secondaryTint = Color(uiColor: dynamicUIColor(
        light: UIColor(red: 0.72, green: 0.43, blue: 0.27, alpha: 1),
        dark: UIColor(red: 0.87, green: 0.62, blue: 0.41, alpha: 1)
    ))
    static let dangerTint = Color(uiColor: dynamicUIColor(
        light: UIColor(red: 0.74, green: 0.27, blue: 0.24, alpha: 1),
        dark: UIColor(red: 0.92, green: 0.45, blue: 0.41, alpha: 1)
    ))
    static let mutedTint = Color(uiColor: dynamicUIColor(
        light: UIColor(red: 0.46, green: 0.48, blue: 0.45, alpha: 1),
        dark: UIColor(red: 0.63, green: 0.67, blue: 0.65, alpha: 1)
    ))
    static let softFill = Color(uiColor: dynamicUIColor(
        light: UIColor(red: 0.89, green: 0.90, blue: 0.85, alpha: 1),
        dark: UIColor(red: 0.18, green: 0.21, blue: 0.20, alpha: 1)
    ))

    static var background: AppBackgroundView {
        AppBackgroundView()
    }

    static var backgroundColor: Color {
        let isBackgroundColorEnabled = UserDefaults.standard.object(
            forKey: AppBackgroundSettings.colorEnabledKey
        ) as? Bool ?? true

        if isBackgroundColorEnabled {
            return Color("AppBackgroundMiddle")
        }

        return Color(uiColor: dynamicUIColor(light: .white, dark: .black))
    }

    static let cardGradient = LinearGradient(
        colors: [
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 0.96),
                dark: UIColor(red: 0.12, green: 0.15, blue: 0.16, alpha: 0.96)
            )),
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 0.92),
                dark: UIColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 0.92)
            ))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = LinearGradient(
        colors: [
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.33, green: 0.49, blue: 0.39, alpha: 1),
                dark: UIColor(red: 0.44, green: 0.63, blue: 0.52, alpha: 1)
            )),
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.22, green: 0.33, blue: 0.27, alpha: 1),
                dark: UIColor(red: 0.20, green: 0.29, blue: 0.25, alpha: 1)
            ))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.78, green: 0.50, blue: 0.34, alpha: 1),
                dark: UIColor(red: 0.48, green: 0.29, blue: 0.18, alpha: 1)
            )),
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.44, green: 0.55, blue: 0.41, alpha: 1),
                dark: UIColor(red: 0.23, green: 0.35, blue: 0.28, alpha: 1)
            )),
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.25, green: 0.35, blue: 0.31, alpha: 1),
                dark: UIColor(red: 0.10, green: 0.16, blue: 0.14, alpha: 1)
            ))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let border = Color("AppBorder")
    static let shadow = Color(uiColor: dynamicUIColor(
        light: UIColor.black.withAlphaComponent(0.08),
        dark: UIColor.black.withAlphaComponent(0.38)
    ))
    static let buttonFill = LinearGradient(
        colors: [
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.91, green: 0.88, blue: 0.80, alpha: 1),
                dark: UIColor(red: 0.23, green: 0.29, blue: 0.27, alpha: 1)
            )),
            Color(uiColor: dynamicUIColor(
                light: UIColor(red: 0.82, green: 0.86, blue: 0.78, alpha: 1),
                dark: UIColor(red: 0.18, green: 0.22, blue: 0.21, alpha: 1)
            ))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let performanceCardFill = Color("AppCardSurface")
    static let performancePanelFill = Color(uiColor: dynamicUIColor(
        light: UIColor.white.withAlphaComponent(0.84),
        dark: UIColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.86)
    ))
    static let performanceSubpanelFill = Color(uiColor: dynamicUIColor(
        light: UIColor.white.withAlphaComponent(0.78),
        dark: UIColor(red: 0.14, green: 0.16, blue: 0.18, alpha: 0.80)
    ))
    static var cardSurface: AnyShapeStyle {
        AnyShapeStyle(performanceCardFill)
    }
    static var panelSurface: AnyShapeStyle {
        AnyShapeStyle(performancePanelFill)
    }
    static var subpanelSurface: AnyShapeStyle {
        AnyShapeStyle(performanceSubpanelFill)
    }
    static var modalSurface: AnyShapeStyle {
        glassMode == .highQualityGlass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(performancePanelFill)
    }
    static let glassPanel = performancePanelFill
    static let glassSubpanel = performanceSubpanelFill
    static let noticeBackground = Color(uiColor: dynamicUIColor(
        light: UIColor.white.withAlphaComponent(0.88),
        dark: UIColor(red: 0.14, green: 0.17, blue: 0.18, alpha: 0.94)
    ))
    static let overlayScrim = Color(uiColor: dynamicUIColor(
        light: UIColor.black.withAlphaComponent(0.20),
        dark: UIColor.black.withAlphaComponent(0.44)
    ))
    static let qrSurface = Color(uiColor: dynamicUIColor(
        light: UIColor.white,
        dark: UIColor(red: 0.15, green: 0.17, blue: 0.19, alpha: 1)
    ))
    static let ghostFill = Color(uiColor: dynamicUIColor(
        light: UIColor.black.withAlphaComponent(0.16),
        dark: UIColor.white.withAlphaComponent(0.10)
    ))

    static func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        let titleColor = dynamicUIColor(
            light: UIColor(red: 0.12, green: 0.14, blue: 0.15, alpha: 1),
            dark: UIColor(red: 0.92, green: 0.94, blue: 0.93, alpha: 1)
        )
        let tintColor = dynamicUIColor(
            light: UIColor(red: 0.24, green: 0.39, blue: 0.31, alpha: 1),
            dark: UIColor(red: 0.55, green: 0.73, blue: 0.62, alpha: 1)
        )

        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: titleColor
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: titleColor
        ]

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.tintColor = tintColor
        navigationBar.prefersLargeTitles = true
    }

    private static func dynamicUIColor(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

struct AppScreen<Content: View>: View {
    @AppStorage(AppBackgroundSettings.colorEnabledKey) private var isBackgroundColorEnabled = true
    private let content: () -> Content
    private let fixedTopContent: (() -> AnyView)?
    private let bottomContentPadding: CGFloat
    private let keyboardDismissMode: ScrollDismissesKeyboardMode
    private let sizeChangeScrollAnchor: UnitPoint?
    private let scrollResetID: AnyHashable?
    private let onScrollDirectionChange: ((AppVerticalScrollDirection) -> Void)?
    private let onBottomProximityChange: ((Bool) -> Void)?

    init(
        bottomContentPadding: CGFloat = 28,
        keyboardDismissMode: ScrollDismissesKeyboardMode = .automatic,
        sizeChangeScrollAnchor: UnitPoint? = nil,
        scrollResetID: AnyHashable? = nil,
        onScrollDirectionChange: ((AppVerticalScrollDirection) -> Void)? = nil,
        onBottomProximityChange: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.bottomContentPadding = bottomContentPadding
        self.keyboardDismissMode = keyboardDismissMode
        self.sizeChangeScrollAnchor = sizeChangeScrollAnchor
        self.scrollResetID = scrollResetID
        self.onScrollDirectionChange = onScrollDirectionChange
        self.onBottomProximityChange = onBottomProximityChange
        self.fixedTopContent = nil
        self.content = content
    }

    init<FixedTopContent: View>(
        bottomContentPadding: CGFloat = 28,
        keyboardDismissMode: ScrollDismissesKeyboardMode = .automatic,
        sizeChangeScrollAnchor: UnitPoint? = nil,
        scrollResetID: AnyHashable? = nil,
        onScrollDirectionChange: ((AppVerticalScrollDirection) -> Void)? = nil,
        onBottomProximityChange: ((Bool) -> Void)? = nil,
        @ViewBuilder fixedTopContent: @escaping () -> FixedTopContent,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.bottomContentPadding = bottomContentPadding
        self.keyboardDismissMode = keyboardDismissMode
        self.sizeChangeScrollAnchor = sizeChangeScrollAnchor
        self.scrollResetID = scrollResetID
        self.onScrollDirectionChange = onScrollDirectionChange
        self.onBottomProximityChange = onBottomProximityChange
        self.fixedTopContent = { AnyView(fixedTopContent()) }
        self.content = content
    }

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            if isBackgroundColorEnabled {
                Circle()
                    .fill(AppTheme.secondaryTint.opacity(0.18))
                    .frame(width: 260, height: 260)
                    .blur(radius: 44)
                    .offset(x: 120, y: -260)

                Circle()
                    .fill(AppTheme.primaryTint.opacity(0.12))
                    .frame(width: 300, height: 300)
                    .blur(radius: 52)
                    .offset(x: -130, y: 340)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, bottomContentPadding)
            }
            .scrollDismissesKeyboard(keyboardDismissMode)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let fixedTopContent {
                    fixedTopContent()
                }
            }
            .defaultScrollAnchor(sizeChangeScrollAnchor, for: .sizeChanges)
            .appObserveBottomProximity(isEnabled: onBottomProximityChange != nil) { isNearBottom in
                onBottomProximityChange?(isNearBottom)
            }
            .appObserveVerticalScroll(isEnabled: onScrollDirectionChange != nil) { direction in
                onScrollDirectionChange?(direction)
            }
            .id(scrollResetID)
        }
    }

}

enum AppVerticalScrollDirection {
    case up
    case down
}

private struct AppVerticalScrollObserver: ViewModifier {
    let isEnabled: Bool
    let threshold: CGFloat
    let onDirectionChange: (AppVerticalScrollDirection) -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldOffset, newOffset in
                guard isEnabled else { return }
                let delta = newOffset - oldOffset
                guard abs(delta) >= threshold else { return }
                onDirectionChange(delta > 0 ? .down : .up)
            }
    }
}

private struct AppBottomProximityObserver: ViewModifier {
    let isEnabled: Bool
    let threshold: CGFloat
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                guard isEnabled else { return true }
                let distance = geometry.contentSize.height - geometry.visibleRect.maxY
                return distance <= threshold
            } action: { oldValue, newValue in
                guard isEnabled, oldValue != newValue else { return }
                onChange(newValue)
            }
    }
}

private struct AppBottomFloatingVisibilityModifier: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isHidden ? 160 : 0)
            .allowsHitTesting(!isHidden)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.88), value: isHidden)
    }
}

extension View {
    func appObserveVerticalScroll(
        isEnabled: Bool = true,
        threshold: CGFloat = 8,
        onDirectionChange: @escaping (AppVerticalScrollDirection) -> Void
    ) -> some View {
        modifier(AppVerticalScrollObserver(
            isEnabled: isEnabled,
            threshold: threshold,
            onDirectionChange: onDirectionChange
        ))
    }

    func appObserveBottomProximity(
        isEnabled: Bool = true,
        threshold: CGFloat = 64,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        modifier(AppBottomProximityObserver(
            isEnabled: isEnabled,
            threshold: threshold,
            onChange: onChange
        ))
    }

    func appBottomFloatingVisibility(isHidden: Bool) -> some View {
        modifier(AppBottomFloatingVisibilityModifier(isHidden: isHidden))
    }

    @ViewBuilder
    func appNativeSearch(
        text: Binding<String>,
        prompt: String,
        isEnabled: Bool = true
    ) -> some View {
        if isEnabled {
            searchable(text: text, placement: .toolbar, prompt: Text(prompt))
                .searchToolbarBehavior(.automatic)
        } else {
            self
        }
    }
}

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow.opacity(0.85), radius: 12, x: 0, y: 7)
    }
}

private struct AppEditorSheetStyleModifier: ViewModifier {
    let initialHeight: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let initialHeight {
            content
                .presentationDetents([.height(initialHeight), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.disabled)
        } else {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.disabled)
        }
    }
}

extension View {
    func appEditorSheetStyle(initialHeight: CGFloat? = nil) -> some View {
        modifier(AppEditorSheetStyleModifier(initialHeight: initialHeight))
    }
}

struct AppSectionHeader: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
            }
        }
    }
}

struct AppStatRow: View {
    let title: String
    let value: String
    var accent: Color = AppTheme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedTint)
            Spacer(minLength: 12)
            AppSelectableText(
                text: value,
                textStyle: .subheadline,
                weight: .semibold,
                color: accent,
                textAlignment: .right
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct AppSelectableText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var weight: UIFont.Weight = .regular
    var pointSize: CGFloat?
    var design: UIFontDescriptor.SystemDesign?
    var color: Color = AppTheme.ink
    var textAlignment: NSTextAlignment = .natural
    var maxHeight: CGFloat?
    var isScrollEnabled = false
    var isUnderlined = false
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = onTap == nil && onLongPress == nil
        textView.isScrollEnabled = isScrollEnabled
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        tapGesture.cancelsTouchesInView = true
        tapGesture.delegate = context.coordinator
        tapGesture.isEnabled = onTap != nil

        let longPressGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressGesture.minimumPressDuration = 0.45
        longPressGesture.cancelsTouchesInView = true
        longPressGesture.delegate = context.coordinator
        longPressGesture.isEnabled = onLongPress != nil

        tapGesture.require(toFail: longPressGesture)
        context.coordinator.tapGesture = tapGesture
        context.coordinator.longPressGesture = longPressGesture
        textView.addGestureRecognizer(tapGesture)
        textView.addGestureRecognizer(longPressGesture)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.tapGesture?.isEnabled = onTap != nil
        context.coordinator.longPressGesture?.isEnabled = onLongPress != nil
        textView.isSelectable = onTap == nil && onLongPress == nil
        if textView.text != text {
            textView.text = text
        }
        textView.font = scaledFont()
        textView.textColor = UIColor(color)
        textView.textAlignment = textAlignment
        textView.isScrollEnabled = isScrollEnabled
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        if isUnderlined {
            textView.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        } else {
            textView.textStorage.removeAttribute(.underlineStyle, range: fullRange)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return nil }
        let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(targetSize)
        let height = maxHeight.map { min(size.height, $0) } ?? size.height
        return CGSize(width: width, height: height)
    }

    private func scaledFont() -> UIFont {
        let baseSize = pointSize ?? UIFont.preferredFont(forTextStyle: textStyle).pointSize
        let systemFont = UIFont.systemFont(ofSize: baseSize, weight: weight)
        let font: UIFont

        if let design, let descriptor = systemFont.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: descriptor, size: baseSize)
        } else {
            font = systemFont
        }

        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onLongPress: (() -> Void)?
        weak var tapGesture: UITapGestureRecognizer?
        weak var longPressGesture: UILongPressGestureRecognizer?

        init(onTap: (() -> Void)?, onLongPress: (() -> Void)?) {
            self.onTap = onTap
            self.onLongPress = onLongPress
        }

        @objc func handleTap() {
            onTap?()
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer !== tapGesture && gestureRecognizer !== longPressGesture
        }
    }
}

struct AppBadge: View {
    let text: String
    var tint: Color = AppTheme.primaryTint

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

struct AppActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(AppTheme.buttonFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.primaryTint.opacity(0.18), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .appTapHaptic()
    }
}

enum AppNativeIconControlPlacement {
    case floating
    case compactFloating
    case inline
}

private struct AppNativeIconControlModifier: ViewModifier {
    let placement: AppNativeIconControlPlacement
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        switch placement {
        case .floating:
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(tint)
        case .compactFloating:
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .tint(tint)
        case .inline:
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .tint(tint)
        }
    }
}

extension View {
    func appNativeIconControl(
        _ placement: AppNativeIconControlPlacement,
        tint: Color = AppTheme.primaryTint
    ) -> some View {
        modifier(AppNativeIconControlModifier(placement: placement, tint: tint))
    }
}

struct AppInlineIconButton: View {
    let systemName: String
    let tint: Color
    let action: () -> Void

    private var title: String {
        switch systemName {
        case "pencil":
            "Редактировать"
        case "trash":
            "Удалить"
        default:
            "Действие"
        }
    }

    var body: some View {
        Button(title, systemImage: systemName) {
            AppHaptics.trigger()
            action()
        }
        .labelStyle(.iconOnly)
        .appNativeIconControl(.inline, tint: tint)
    }
}

struct AppNoticeBanner: View {
    let text: String
    var tint: Color = AppTheme.primaryTint
    var isCritical = false
    var style: AppGlobalBannerStyle? = nil

    var body: some View {
        EmptyView()
            .task(id: text) {
                if AppErrorPresentation.isDomainMessage(text) {
                    AppBannerCenter.shared.show(
                        text,
                        style: style ?? (isCritical ? .error : .success)
                    )
                } else {
                    AppErrorPresentation.presentIfNeeded(message: text)
                }
            }
    }
}

struct AppEmptyState: View {
    let title: String
    let message: String
    let systemName: String

    var body: some View {
        AppCard {
            VStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryTint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

enum AppClipboard {
    static func copy(_ value: String, message: String = "Скопировано") {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = trimmed
        AppBannerCenter.shared.show(message, style: .success)
    }

    static func copyTerminalID(_ value: String) {
        AppHaptics.trigger()
        copy(value, message: "ID терминала скопирован")
    }
}

struct AppDateField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: { Self.parse(text) ?? Date() },
                set: { text = Self.formatter.string(from: $0) }
            ),
            displayedComponents: [.date]
        )
        .environment(\.locale, AppLocale.russian)
        .datePickerStyle(.compact)
        .onAppear {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = Self.formatter.string(from: Date())
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return formatter.date(from: trimmed)
    }
}

struct AppMonthField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: { Self.parse(text) ?? Date() },
                set: { text = Self.storageFormatter.string(from: $0) }
            ),
            displayedComponents: [.date]
        )
        .environment(\.locale, AppLocale.russian)
        .datePickerStyle(.compact)
        .onAppear {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = Self.storageFormatter.string(from: Date())
            }
        }
    }

    private static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let parsingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parsingFormatter.date(from: "\(trimmed)-01")
    }
}
