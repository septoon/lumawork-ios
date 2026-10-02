import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

enum AppNavigationSection: String, CaseIterable, Identifiable {
    case home
    case backpack
    case employees
    case maintenance
    case fuel
    case wiki
    case ftp
    case salary
    case requests
    case coordination
    case timeReport
    case analytics
    case users

    var id: String { rawValue }

    static func availableCases(isAdmin: Bool) -> [AppNavigationSection] {
        allCases.filter { section in
            section != .users || isAdmin
        }
    }

    var title: String {
        switch self {
        case .home:
            "Главная"
        case .backpack:
            "Мой рюкзак"
        case .employees:
            "Сотрудники"
        case .maintenance:
            "Авто"
        case .fuel:
            "Топливо"
        case .wiki:
            "Помощник"
        case .ftp:
            "FTP"
        case .salary:
            "Зарплата"
        case .requests:
            "Заявки"
        case .coordination:
            "Координация"
        case .timeReport:
            "Трудозатраты"
        case .analytics:
            "Аналитика"
        case .users:
            "Админка"
        }
    }

    var subtitle: String {
        switch self {
        case .home:
            "Маршрут инженера"
        case .backpack:
            "Оборудование ЗИП"
        case .employees:
            "Команда и контакты"
        case .maintenance:
            "Автомобили и обслуживание"
        case .fuel:
            "Лимиты и заправки"
        case .wiki:
            "Помощник и база знаний"
        case .ftp:
            "Файлы Сервионики"
        case .salary:
            "Выплаты и документы"
        case .requests:
            "SimpleOne и архив"
        case .coordination:
            "Инженеры и активные заявки"
        case .timeReport:
            "Работа и дорога"
        case .analytics:
            "Сводка заявок"
        case .users:
            "Контроль приложения и сервера"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house.fill"
        case .backpack:
            "backpack.fill"
        case .employees:
            "person.2.fill"
        case .maintenance:
            "car.fill"
        case .fuel:
            "fuelpump.fill"
        case .wiki:
            "bubble.left.and.text.bubble.right.fill"
        case .ftp:
            "externaldrive.connected.to.line.below.fill"
        case .salary:
            "rublesign.circle.fill"
        case .requests:
            "checklist.checked"
        case .coordination:
            "person.line.dotted.person.fill"
        case .timeReport:
            "clock.badge.checkmark.fill"
        case .analytics:
            "chart.bar.xaxis"
        case .users:
            "person.3.fill"
        }
    }
}

private enum AppSidebarChrome {
    static let screenCornerRadius: CGFloat = 56

    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black
            : UIColor.white
    })

    static let surfaceBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.23)
            : UIColor(white: 1, alpha: 0.42)
    })

    static let surfaceShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.42)
            : UIColor(white: 0, alpha: 0.12)
    })

    static let primaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.08, green: 0.10, blue: 0.11, alpha: 1)
    })

    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.86)
            : UIColor(red: 0.23, green: 0.26, blue: 0.27, alpha: 1)
    })

    static let selectedRowBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.13)
            : UIColor(white: 0, alpha: 0.08)
    })

    static let refreshingTitle = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.58)
            : UIColor(red: 0.08, green: 0.10, blue: 0.11, alpha: 1)
    })

    static let shimmerHighlight = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 1)
            : UIColor(white: 1, alpha: 0.96)
    })
}

private enum AppSidebarRefreshMetrics {
    static let threshold: CGFloat = 82
    static let titleParallaxFactor: CGFloat = 0.4
}

private enum AppSidebarRefreshState: Equatable {
    case idle
    case pulling(didTriggerThresholdHaptic: Bool)
    case armed
    case refreshing

    var isRefreshing: Bool {
        self == .refreshing
    }
}

extension View {
    func appSidebarBackButton() -> some View {
        navigationBarBackButtonHidden(false)
    }
}

struct AppSidebarShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedSection: AppNavigationSection
    @Binding var isMenuPresented: Bool
    @State private var dragOffset: CGFloat = 0
    @State private var visibleRootSection: AppNavigationSection?

    private let sessionStore: AppSessionStore
    private let routeStore: HomeRouteStore
    private let vehicleStore: VehicleStore
    private let feedbackStore: FeedbackStore
    private let workDocumentsStore: WorkDocumentsStore
    private let navigationVisibilityStore: AppNavigationVisibilityStore
    private let groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    private let refreshHomeData: () async -> Void
    private let content: Content

    init(
        selectedSection: Binding<AppNavigationSection>,
        isMenuPresented: Binding<Bool>,
        sessionStore: AppSessionStore,
        routeStore: HomeRouteStore,
        vehicleStore: VehicleStore,
        feedbackStore: FeedbackStore,
        workDocumentsStore: WorkDocumentsStore,
        navigationVisibilityStore: AppNavigationVisibilityStore,
        groupClosedRequestsStore: CoordinationGroupClosedRequestsStore,
        refreshHomeData: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _selectedSection = selectedSection
        _isMenuPresented = isMenuPresented
        _visibleRootSection = State(initialValue: selectedSection.wrappedValue)
        self.sessionStore = sessionStore
        self.routeStore = routeStore
        self.vehicleStore = vehicleStore
        self.feedbackStore = feedbackStore
        self.workDocumentsStore = workDocumentsStore
        self.navigationVisibilityStore = navigationVisibilityStore
        self.groupClosedRequestsStore = groupClosedRequestsStore
        self.refreshHomeData = refreshHomeData
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let menuWidth = min(max(geometry.size.width * 0.738, 258), 306)
            let offset = currentOffset(menuWidth: menuWidth)
            let progress = offset / menuWidth

            ZStack(alignment: .leading) {
                AppSidebarMenu(
                    selectedSection: $selectedSection,
                    revealProgress: progress,
                    reduceMotion: reduceMotion,
                    closeMenu: closeMenu,
                    sessionStore: sessionStore,
                    routeStore: routeStore,
                    vehicleStore: vehicleStore,
                    feedbackStore: feedbackStore,
                    workDocumentsStore: workDocumentsStore,
                    navigationVisibilityStore: navigationVisibilityStore,
                    groupClosedRequestsStore: groupClosedRequestsStore,
                    onRefresh: refreshHomeData
                )
                .frame(width: menuWidth)
                .frame(maxHeight: .infinity)
                .zIndex(0)

                ZStack {
                    ZStack {
                        AppTheme.background
                            .ignoresSafeArea()

                        NavigationStack {
                            content
                                .modifier(
                                    AppSidebarRootVisibilityModifier(
                                        section: selectedSection,
                                        updateVisibility: updateRootVisibility
                                    )
                                )
                                .toolbar {
                                    if isRootScreenVisible {
                                        ToolbarItem(placement: .topBarLeading) {
                                            AppSidebarMenuButton {
                                                openMenu()
                                            }
                                        }
                                    }
                                }
                        }
                        .id(selectedSection)
                    }

                    Color.black
                        .opacity(0.08 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .allowsHitTesting(progress > 0.01)
                        .onTapGesture {
                            closeMenu()
                        }
                }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .modifier(AppSidebarSurfaceModifier(progress: progress))
                    .offset(x: offset)
                    .zIndex(1)

                SidebarPanGestureLayer(
                    isMenuPresented: isMenuPresented,
                    canOpenMenu: isRootScreenVisible,
                    menuWidth: menuWidth,
                    onChanged: updateDragOffset,
                    onEnded: finishDrag
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(2)
            }
            .background(AppSidebarChrome.background.ignoresSafeArea())
            .animation(menuAnimation, value: isMenuPresented)
            .onChange(of: selectedSection) { _, _ in
                visibleRootSection = selectedSection
            }
        }
        .ignoresSafeArea()
    }

    private func currentOffset(menuWidth: CGFloat) -> CGFloat {
        let baseOffset = isMenuPresented ? menuWidth : 0
        return min(max(baseOffset + dragOffset, 0), menuWidth)
    }

    private var isRootScreenVisible: Bool {
        visibleRootSection == selectedSection
    }

    private func updateRootVisibility(
        section: AppNavigationSection,
        isVisible: Bool
    ) {
        if isVisible {
            visibleRootSection = section
        } else if visibleRootSection == section {
            visibleRootSection = nil
        }
    }

    private func updateDragOffset(_ translation: CGFloat, menuWidth: CGFloat) {
        if isMenuPresented {
            dragOffset = min(max(translation, -menuWidth), 0)
        } else {
            if dragOffset == 0, translation > 0 {
                dismissKeyboard()
            }
            dragOffset = min(max(translation, 0), menuWidth)
        }
    }

    private func finishDrag(_ translation: CGFloat, velocity: CGFloat, menuWidth: CGFloat) {
        let shouldOpen: Bool
        if isMenuPresented {
            shouldOpen = !(translation < -menuWidth * 0.20 || velocity < -650)
        } else {
            shouldOpen = translation > menuWidth * 0.18 || velocity > 650
        }
        let didChangePresentation = shouldOpen != isMenuPresented

        if didChangePresentation {
            AppHaptics.trigger(.expandCollapse)
        }

        if shouldOpen {
            dismissKeyboard()
        }

        withAnimation(menuAnimation) {
            isMenuPresented = shouldOpen
            dragOffset = 0
        }
    }

    private func openMenu() {
        dismissKeyboard()
        withAnimation(menuAnimation) {
            isMenuPresented = true
        }
    }

    private func closeMenu() {
        withAnimation(menuAnimation) {
            isMenuPresented = false
        }
    }

    private var menuAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .interactiveSpring(response: 0.36, dampingFraction: 0.88)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct AppSidebarRootVisibilityModifier: ViewModifier {
    let section: AppNavigationSection
    let updateVisibility: (AppNavigationSection, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateVisibility(section, true)
            }
            .onDisappear {
                updateVisibility(section, false)
            }
    }
}

private struct SidebarPanGestureLayer: UIViewRepresentable {
    let isMenuPresented: Bool
    let canOpenMenu: Bool
    let menuWidth: CGFloat
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        SidebarPanInstallerView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SidebarPanGestureLayer

        init(_ parent: SidebarPanGestureLayer) {
            self.parent = parent
        }

        @objc
        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            let velocity = recognizer.velocity(in: recognizer.view).x

            switch recognizer.state {
            case .changed:
                parent.onChanged(translation, parent.menuWidth)
            case .ended, .cancelled, .failed:
                parent.onEnded(translation, velocity, parent.menuWidth)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.35 else { return false }
            if parent.isMenuPresented {
                return velocity.x < 0
            }
            return parent.canOpenMenu && velocity.x > 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

private final class SidebarPanInstallerView: UIView {
    private weak var coordinator: SidebarPanGestureLayer.Coordinator?
    private weak var installedWindow: UIWindow?
    private var recognizer: UIPanGestureRecognizer?

    init(coordinator: SidebarPanGestureLayer.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let recognizer {
            installedWindow?.removeGestureRecognizer(recognizer)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if installedWindow !== window, let recognizer {
            installedWindow?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }

        guard let window, let coordinator, recognizer == nil else { return }

        let recognizer = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(SidebarPanGestureLayer.Coordinator.handlePan(_:))
        )
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = coordinator
        window.addGestureRecognizer(recognizer)

        self.recognizer = recognizer
        installedWindow = window
    }
}

struct AppSidebarMenuButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.trigger(.expandCollapse)
            action()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(AppSidebarChrome.primaryText)
                    .frame(width: 22, height: 3)

                Capsule()
                    .fill(AppSidebarChrome.primaryText)
                    .frame(width: 13.2, height: 3)
            }
            .frame(width: 22, height: 18)
        }
        .accessibilityLabel("Открыть меню")
    }
}

private struct AppSidebarMenu: View {
    @Binding var selectedSection: AppNavigationSection
    let revealProgress: CGFloat
    let reduceMotion: Bool
    let closeMenu: () -> Void
    let sessionStore: AppSessionStore
    let routeStore: HomeRouteStore
    let vehicleStore: VehicleStore
    let feedbackStore: FeedbackStore
    let workDocumentsStore: WorkDocumentsStore
    let navigationVisibilityStore: AppNavigationVisibilityStore
    let groupClosedRequestsStore: CoordinationGroupClosedRequestsStore
    let onRefresh: () async -> Void
    @State private var isSettingsPresented = false
    @State private var feedbackPresentation: FeedbackPresentation?
    @State private var refreshState: AppSidebarRefreshState = .idle
    @State private var pullDistance: CGFloat = 0
    @State private var scrollPhase: ScrollPhase = .idle

    var body: some View {
        let visibleSections = navigationVisibilityStore.visibleCases(isAdmin: sessionStore.isAdmin)

        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .topLeading) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleSections) { section in
                            Button {
                                AppHaptics.trigger(.expandCollapse)
                                selectedSection = section
                                closeMenu()
                            } label: {
                                AppSidebarMenuRow(
                                    section: section,
                                    isSelected: selectedSection == section,
                                    isLoadingGroupRequests: section == .coordination && groupClosedRequestsStore.isLoading
                                )
                            }
                            .buttonStyle(.plain)
                            .modifier(AppSidebarTitleOcclusionModifier())
                        }
                    }
                    .padding(.top, 81)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(-(geometry.contentOffset.y + geometry.contentInsets.top), 0)
                } action: { _, newPullDistance in
                    updatePullDistance(newPullDistance)
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    updateScrollPhase(from: oldPhase, to: newPhase)
                }

                AppSidebarTitle(
                    isRefreshing: refreshState.isRefreshing,
                    reduceMotion: reduceMotion
                )
                    .padding(.top, 18)
                    .offset(y: titlePullOffset)
                    .animation(refreshReturnAnimation, value: refreshState.isRefreshing)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                AppSidebarSettingsButton {
                    AppHaptics.trigger(.expandCollapse)
                    isSettingsPresented = true
                }

                Spacer()

                AppSidebarFeedbackButton {
                    AppHaptics.trigger(.expandCollapse)
                    feedbackPresentation = FeedbackPresentation(
                        initialArea: FeedbackArea.current(selectedSection),
                        includesAdminArea: sessionStore.isAdmin
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 42)
        .padding(.bottom, 28)
        .modifier(
            AppSidebarMenuDepthModifier(
                progress: revealProgress,
                reduceMotion: reduceMotion
            )
        )
        .background(AppSidebarChrome.background.ignoresSafeArea())
        .allowsHitTesting(revealProgress > 0.98)
        .accessibilityHidden(revealProgress < 0.98)
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                AppSidebarSettingsPlaceholder(
                    sessionStore: sessionStore,
                    routeStore: routeStore,
                    vehicleStore: vehicleStore,
                    workDocumentsStore: workDocumentsStore,
                    navigationVisibilityStore: navigationVisibilityStore
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $feedbackPresentation) { destination in
            FeedbackScreen(
                store: feedbackStore,
                initialArea: destination.initialArea,
                includesAdminArea: destination.includesAdminArea
            )
        }
        .task(id: refreshState.isRefreshing) {
            guard refreshState.isRefreshing else { return }
            await onRefresh()
            guard !Task.isCancelled else { return }
            refreshState = .idle
        }
    }

    private var titlePullOffset: CGFloat {
        guard !refreshState.isRefreshing else { return 0 }
        return pullDistance * AppSidebarRefreshMetrics.titleParallaxFactor
    }

    private var refreshReturnAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .interactiveSpring(response: 0.38, dampingFraction: 0.86)
    }

    private func updatePullDistance(_ newPullDistance: CGFloat) {
        guard !refreshState.isRefreshing, scrollPhase == .interacting else { return }

        pullDistance = newPullDistance

        switch refreshState {
        case .idle where newPullDistance > 0:
            refreshState = .pulling(didTriggerThresholdHaptic: false)
        case let .pulling(didTriggerThresholdHaptic)
            where newPullDistance >= AppSidebarRefreshMetrics.threshold:
            refreshState = .armed
            if !didTriggerThresholdHaptic {
                AppHaptics.trigger(.refreshThreshold)
            }
        case .armed where newPullDistance < AppSidebarRefreshMetrics.threshold:
            refreshState = .pulling(didTriggerThresholdHaptic: true)
        case .idle, .pulling, .armed, .refreshing:
            break
        }
    }

    private func updateScrollPhase(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        scrollPhase = newPhase
        guard !refreshState.isRefreshing else { return }

        if newPhase == .interacting {
            if pullDistance > 0, refreshState == .idle {
                refreshState = .pulling(didTriggerThresholdHaptic: false)
            }
            return
        }

        guard oldPhase == .interacting else { return }

        switch refreshState {
        case .armed:
            withAnimation(refreshReturnAnimation) {
                refreshState = .refreshing
                pullDistance = 0
            }
        case .pulling:
            withAnimation(refreshReturnAnimation) {
                refreshState = .idle
                pullDistance = 0
            }
        case .idle, .refreshing:
            break
        }
    }
}

private struct AppSidebarTitleOcclusionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.visualEffect { effect, geometry in
            effect
                .blur(radius: occlusionProgress(for: geometry) * 10)
                .opacity(1 - Double(occlusionProgress(for: geometry)) * 0.72)
        }
    }

    nonisolated private func occlusionProgress(for geometry: GeometryProxy) -> CGFloat {
        let rowTop = geometry.frame(in: .scrollView(axis: .vertical)).minY
        return min(max((50 - rowTop) / 52, 0), 1)
    }
}

private struct AppSidebarTitle: View {
    let isRefreshing: Bool
    let reduceMotion: Bool
    @State private var shimmerStartedAt = Date()

    var body: some View {
        title
            .foregroundStyle(
                isRefreshing
                    ? AppSidebarChrome.refreshingTitle
                    : AppSidebarChrome.primaryText
            )
            .overlay {
                if isRefreshing {
                    TimelineView(
                        .animation(
                            minimumInterval: reduceMotion ? 1.0 / 30.0 : nil,
                            paused: false
                        )
                    ) { timeline in
                        GeometryReader { geometry in
                            shimmerBand(
                                size: geometry.size,
                                progress: shimmerProgress(at: timeline.date)
                            )
                        }
                    }
                    .mask(title)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: isRefreshing) { _, isRefreshing in
                if isRefreshing {
                    shimmerStartedAt = Date()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Инженер")
            .accessibilityValue(isRefreshing ? "Обновление данных" : "")
    }

    private var title: some View {
        Text("Инженер")
            .font(.largeTitle.weight(.regular))
    }

    private func shimmerBand(size: CGSize, progress: CGFloat) -> some View {
        let bandWidth = max(size.width * 0.46, 1)
        let bandHeight = max(size.height * 3, 1)
        let diagonalOverflow = size.height
        let travelDistance = size.width + bandWidth + diagonalOverflow * 2

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: AppSidebarChrome.shimmerHighlight.opacity(0.18), location: 0.28),
                .init(color: AppSidebarChrome.shimmerHighlight, location: 0.5),
                .init(color: AppSidebarChrome.shimmerHighlight.opacity(0.18), location: 0.72),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: bandWidth, height: bandHeight)
        .rotationEffect(.degrees(-45))
        .offset(
            x: -bandWidth - diagonalOverflow + travelDistance * progress,
            y: (size.height - bandHeight) / 2
        )
    }

    private func shimmerProgress(at date: Date) -> CGFloat {
        let duration = reduceMotion ? 1.8 : 1.25
        let elapsed = max(date.timeIntervalSince(shimmerStartedAt), 0)
        return CGFloat(elapsed.truncatingRemainder(dividingBy: duration) / duration)
    }
}

private struct FeedbackPresentation: Identifiable {
    let id = UUID()
    let initialArea: FeedbackArea
    let includesAdminArea: Bool
}

private struct AppSidebarMenuDepthModifier: AnimatableModifier {
    var progress: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let revealProgress = resolvedProgress

        content
            .opacity(revealProgress)
            .scaleEffect(
                reduceMotion ? 1 : 0.955 + 0.045 * revealProgress,
                anchor: UnitPoint(x: 0.52, y: 0.42)
            )
    }

    private var resolvedProgress: CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        return min(clampedProgress / 0.78, 1)
    }
}

private struct AppSidebarSurfaceModifier: AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let isSeparated = progress > 0.0001

        content
            .clipShape(AppSidebarScreenShape(isRounded: isSeparated))
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppSidebarChrome.screenCornerRadius,
                    style: .continuous
                )
                .strokeBorder(AppSidebarChrome.surfaceBorder, lineWidth: 0.5)
                .opacity(isSeparated ? 1 : 0)
            }
            .compositingGroup()
            .shadow(
                color: isSeparated ? AppSidebarChrome.surfaceShadow : .clear,
                radius: 22,
                x: -7,
                y: 0
            )
    }
}

private struct AppSidebarScreenShape: Shape {
    let isRounded: Bool

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: isRounded ? AppSidebarChrome.screenCornerRadius : 0,
            style: .continuous
        )
        .path(in: rect)
    }
}

private struct AppSidebarSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button("Настройки", systemImage: "gearshape") {
            action()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 22))
        .controlSize(.regular)
        .appNativeIconControl(.floating, tint: AppSidebarChrome.primaryText)
    }
}

private struct AppSidebarFeedbackButton: View {
    let action: () -> Void

    var body: some View {
        Button("Обратная связь", systemImage: "ladybug.fill") {
            action()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 22))
        .controlSize(.regular)
        .appNativeIconControl(.floating, tint: AppSidebarChrome.primaryText)
        .accessibilityLabel("Обратная связь")
    }
}

private struct AppSidebarMenuRow: View {
    let section: AppNavigationSection
    let isSelected: Bool
    let isLoadingGroupRequests: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppSidebarChrome.primaryText : AppSidebarChrome.secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppSidebarChrome.primaryText : AppSidebarChrome.secondaryText)
                if isLoadingGroupRequests {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppSidebarChrome.secondaryText)
                        Text("Загрузка заявок группы")
                            .font(.caption)
                            .foregroundStyle(AppSidebarChrome.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppSidebarChrome.selectedRowBackground)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct AppSidebarSettingsPlaceholder: View {
    @Environment(\.dismiss) private var dismiss
    let sessionStore: AppSessionStore
    let routeStore: HomeRouteStore
    let vehicleStore: VehicleStore
    let workDocumentsStore: WorkDocumentsStore
    let navigationVisibilityStore: AppNavigationVisibilityStore
    @AppStorage(SalaryPasscodeSettings.faceIDEnabledKey) private var isSalaryFaceIDEnabled = true
    @State private var gsmProfileStore: GsmProfileSettingsStore
    @State private var isFaceIDAvailable = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var isAvatarFileImporterPresented = false
    @State private var isAvatarRemovalConfirmationPresented = false

    init(
        sessionStore: AppSessionStore,
        routeStore: HomeRouteStore,
        vehicleStore: VehicleStore,
        workDocumentsStore: WorkDocumentsStore,
        navigationVisibilityStore: AppNavigationVisibilityStore
    ) {
        self.sessionStore = sessionStore
        self.routeStore = routeStore
        self.vehicleStore = vehicleStore
        self.workDocumentsStore = workDocumentsStore
        self.navigationVisibilityStore = navigationVisibilityStore
        _gsmProfileStore = State(initialValue: GsmProfileSettingsStore(
            api: GsmProfileAPI(config: AppConfig(), authToken: sessionStore.authToken),
            cacheID: sessionStore.session?.user.id
        ))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer(minLength: 0)

                    ZStack(alignment: .bottomTrailing) {
                        ProfileAvatar(size: 60, avatarUrl: sessionStore.avatarUrl)

                        avatarActionsMenu
                            .offset(x: 4, y: 4)

                        if sessionStore.isAvatarUploading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: Circle())
                                .frame(width: 60, height: 60, alignment: .center)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let errorMessage = sessionStore.errorMessage,
               AppOfflineWarningPolicy.shouldDisplay(
                   errorMessage,
                   isOfflineMode: sessionStore.isOfflineMode
               ) {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true,
                    style: .error
                )
            }

            Section("Профиль") {
                settingsNavigationLink(
                    "Профиль",
                    systemImage: "person.crop.circle",
                    tint: .blue,
                    destination: .profile
                )
                settingsNavigationLink(
                    "ГСМ профиль",
                    systemImage: "fuelpump",
                    tint: .orange,
                    destination: .gsmProfile
                )
            }

            Section("Маршрут") {
                settingsNavigationLink(
                    "Старт и финиш",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    tint: .green,
                    destination: .route
                )
            }

            Section("Приложение") {
                settingsNavigationLink(
                    "Уведомления",
                    systemImage: "bell.badge",
                    tint: .red,
                    destination: .notifications
                )
                settingsNavigationLink(
                    "Экраны",
                    systemImage: "rectangle.grid.1x2",
                    tint: .indigo,
                    destination: .screens
                )
                settingsNavigationLink(
                    "Оформление",
                    systemImage: "circle.lefthalf.filled",
                    tint: .purple,
                    destination: .appearance
                )
                settingsNavigationLink(
                    "Siri и команды",
                    systemImage: "waveform",
                    tint: .pink,
                    destination: .siri
                )
            }

            Section("Безопасность") {
                Toggle(isOn: $isSalaryFaceIDEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Использовать Face ID")
                            Text(isFaceIDAvailable
                                 ? "Для входа в раздел «Зарплата»"
                                 : "Face ID недоступен на этом устройстве")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        settingsIcon("faceid", tint: .teal)
                    }
                }
                .tint(AppTheme.primaryTint)
                .disabled(!isFaceIDAvailable)
                .onChange(of: isSalaryFaceIDEnabled) { _, _ in
                    AppHaptics.trigger(.expandCollapse)
                }
            }

            Section("Аккаунт") {
                LabeledContent {
                    Text(sessionStore.currentEmail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label {
                        Text("Электронная почта")
                    } icon: {
                        settingsIcon("envelope", tint: .blue)
                    }
                }

                Button(role: .destructive) {
                    AppHaptics.trigger()
                    Task {
                        await sessionStore.logout()
                        dismiss()
                    }
                } label: {
                    Label {
                        Text("Выйти")
                    } icon: {
                        settingsIcon("rectangle.portrait.and.arrow.right", tint: .red)
                    }
                }
            }
        }
        .navigationDestination(for: AppSidebarSettingsDestination.self) { destination in
            switch destination {
            case .profile:
                ProfileSettingsScreen(
                    sessionStore: sessionStore,
                    vehicleStore: vehicleStore,
                    workDocumentsStore: workDocumentsStore
                )
            case .gsmProfile:
                GsmProfileSettingsScreen(
                    store: gsmProfileStore,
                    vehicleStore: vehicleStore
                )
            case .route:
                RouteSettingsScreen(
                    routeStore: routeStore,
                    sessionStore: sessionStore
                )
            case .notifications:
                NotificationSettingsScreen(sessionStore: sessionStore)
            case .screens:
                ScreenVisibilitySettingsScreen(
                    visibilityStore: navigationVisibilityStore,
                    isAdmin: sessionStore.isAdmin
                )
            case .appearance:
                AppearanceSettingsScreen()
            case .siri:
                EngineerSiriSettingsScreen()
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isFaceIDAvailable = SalaryPasscodeSettings.isFaceIDAvailable()
            if !isFaceIDAvailable {
                isSalaryFaceIDEnabled = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton {
                    dismiss()
                }
            }
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task {
                await uploadAvatar(from: item)
                selectedAvatarItem = nil
            }
        }
        .photosPicker(
            isPresented: $isPhotoLibraryPresented,
            selection: $selectedAvatarItem,
            matching: .images
        )
        .fullScreenCover(isPresented: $isCameraPresented) {
            AvatarCameraPicker(isPresented: $isCameraPresented) { image in
                Task {
                    await uploadAvatar(image: image)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isAvatarFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            Task {
                await uploadAvatar(from: result)
            }
        }
        .confirmationDialog(
            "Удалить фото профиля?",
            isPresented: $isAvatarRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                Task {
                    await sessionStore.deleteAvatar()
                    if sessionStore.errorMessage == nil {
                        AppHaptics.trigger()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В профиле снова будет показан стандартный аватар.")
        }
    }

    private var avatarActionsMenu: some View {
        Menu {
            Button {
                isPhotoLibraryPresented = true
            } label: {
                Label("Фотогалерея", systemImage: "photo.on.rectangle")
            }

            Button {
                isCameraPresented = true
            } label: {
                Label("Сделать снимок", systemImage: "camera")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

            Button {
                isAvatarFileImporterPresented = true
            } label: {
                Label("Выбрать файл", systemImage: "folder")
            }

            if sessionStore.avatarUrl != nil {
                Divider()

                Button("Удалить", systemImage: "trash", role: .destructive) {
                    isAvatarRemovalConfirmationPresented = true
                }
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(sessionStore.isAvatarUploading)
        .accessibilityLabel("Изменить фото профиля")
    }

    private func uploadAvatar(from item: PhotosPickerItem) async {
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                sessionStore.errorMessage = "Не удалось подготовить фото."
                return
            }
            await uploadAvatar(data: rawData)
        } catch {
            sessionStore.errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func uploadAvatar(from result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await uploadAvatar(data: try Data(contentsOf: url))
        } catch {
            sessionStore.errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func uploadAvatar(data: Data) async {
        guard let image = UIImage(data: data) else {
            sessionStore.errorMessage = "Выбранный файл не является изображением."
            return
        }
        await uploadAvatar(image: image)
    }

    private func uploadAvatar(image: UIImage) async {
        guard let uploadData = image.avatarJPEGData(maxDimension: 1024, compressionQuality: 0.86) else {
            sessionStore.errorMessage = "Не удалось подготовить фото."
            return
        }
        await sessionStore.uploadAvatar(imageData: uploadData)
    }

    private func settingsNavigationLink(
        _ title: String,
        systemImage: String,
        tint: Color,
        destination: AppSidebarSettingsDestination
    ) -> some View {
        NavigationLink(value: destination) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    settingsIcon(systemImage, tint: tint)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
    }

    private func settingsIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

private enum AppSidebarSettingsDestination: Hashable {
    case profile
    case gsmProfile
    case route
    case notifications
    case screens
    case appearance
    case siri
}

private struct AvatarCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImagePicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: AvatarCameraPicker

        init(parent: AvatarCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.isPresented = false
        }
    }
}

private struct ScreenVisibilitySettingsScreen: View {
    let visibilityStore: AppNavigationVisibilityStore
    let isAdmin: Bool

    private var sections: [AppNavigationSection] {
        AppNavigationSection.availableCases(isAdmin: isAdmin)
    }

    var body: some View {
        AppScreen {
            AppSectionHeader(title: "Экраны")

            AppCard {
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        Toggle(isOn: Binding(
                            get: { visibilityStore.isEnabled(section) },
                            set: { isEnabled in
                                AppHaptics.trigger(.expandCollapse)
                                visibilityStore.setEnabled(section, isEnabled, isAdmin: isAdmin)
                            }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: section.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryTint)
                                    .frame(width: 30, height: 30)
                                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())

                                Text(section.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(!visibilityStore.canDisable(section, isAdmin: isAdmin))
                        .padding(.vertical, 11)

                        if index != sections.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle("Экраны")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension UIImage {
    func avatarJPEGData(maxDimension: CGFloat, compressionQuality: CGFloat) -> Data? {
        let longestSide = max(size.width, size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return image.jpegData(compressionQuality: compressionQuality)
    }
}
