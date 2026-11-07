import SwiftUI

struct LeaderboardContent: View {
    @Bindable var store: LeaderboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var categoryPicker = false
    @State private var periodPicker = false

    var body: some View {
        AppScreen {
            LazyVStack(alignment: .leading, spacing: 16) {
                let filterLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                filterLayout {
                    filterButton(store.category.title, presented: $categoryPicker)
                        .popover(isPresented: $categoryPicker, arrowEdge: .top) {
                            choices(LeaderboardCategory.allCases, selected: store.category, title: { $0.title }) { store.category = $0; categoryPicker = false }
                                .presentationCompactAdaptation(.popover)
                        }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    filterButton(store.period.title, presented: $periodPicker)
                        .popover(isPresented: $periodPicker, arrowEdge: .top) {
                            choices(LeaderboardPeriod.allCases, selected: store.period, title: { $0.title }) { store.period = $0; periodPicker = false }
                                .presentationCompactAdaptation(.popover)
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if store.isRefreshing && !reduceMotion && scenePhase == .active {
                        CoordinationShimmerText(text: "Рейтинг пользователей", font: .headline, tint: AppTheme.ink)
                    } else {
                        Text("Рейтинг пользователей").font(.headline).foregroundStyle(AppTheme.ink)
                    }
                    if let time = store.cacheTime, store.isShowingCache {
                        Text("Сохранённые данные · \(time.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(AppTheme.mutedTint)
                    }
                }
                if let error = store.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(AppTheme.mutedTint)
                        Button("Повторить") { Task { await store.load(refresh: true) } }
                    }
                }
                if store.loading {
                    skeleton
                } else if let response = store.response?.participantsOnly {
                    if let me = response.me {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Моя позиция").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
                            LeaderboardRow(entry: me)
                        }
                        .padding(12)
                        .background(AppTheme.primaryTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 12) {
                        Text("Место").frame(width: 48, alignment: .center)
                        Text("Инженер").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Заявок").frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.mutedTint)
                    }
                    if response.items.isEmpty {
                        Text("Пока нет пользователей с выгрузкой SO.").font(.subheadline).foregroundStyle(AppTheme.mutedTint)
                    }
                    ForEach(response.items) { entry in
                        LeaderboardRow(entry: entry)
                        Divider()
                    }
                    if response.nextOffset != nil {
                        Button { Task { await store.loadNextPage() } } label: {
                            if store.isLoadingPage { ProgressView() } else { Text("Показать ещё") }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(store.isLoadingPage)
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.load(refresh: true) }
    }

    private func filterButton(_ title: String, presented: Binding<Bool>) -> some View {
        Button { presented.wrappedValue = true } label: {
            HStack(spacing: 5) { Text(title); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func choices<T: Hashable>(_ values: [T], selected: T, title: @escaping (T) -> String, choose: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    HStack(spacing: 16) {
                        Text(title(value)).foregroundStyle(AppTheme.ink)
                        Spacer(minLength: 8)
                        if selected == value { Image(systemName: "checkmark").foregroundStyle(AppTheme.primaryTint) }
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }.padding(.vertical, 8).frame(minWidth: 240)
    }

    private var skeleton: some View {
        VStack(spacing: 18) {
            SkeletonPlaceholder(cornerRadius: 12).frame(height: 72)
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonPlaceholder(cornerRadius: 12).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonPlaceholder().frame(width: 150, height: 14)
                        SkeletonPlaceholder().frame(width: 96, height: 10)
                    }
                    Spacer(minLength: 0)
                    SkeletonPlaceholder().frame(width: 50, height: 18)
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Загрузка рейтинга")
    }
}

struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        rank
                        Spacer(minLength: 8)
                        valueLabel
                    }
                    engineerInfo
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    rank.frame(width: 48)
                    engineerInfo.frame(maxWidth: .infinity, alignment: .leading)
                    valueLabel.frame(minWidth: 64, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
    private var engineerInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName)
                .font(.subheadline.weight(entry.isCurrentUser ? .semibold : .medium))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let source = entry.sourceSyncedAt, let date = WorkStatisticsAggregator.parseDate(source) {
                Text("SO · \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(AppTheme.mutedTint)
            }
        }
    }
    private var valueLabel: some View {
        Text(entry.hasData ? (entry.value ?? 0).formatted() : "Нет данных")
            .font(entry.hasData ? .subheadline.weight(.semibold) : .caption)
            .foregroundStyle(entry.hasData ? AppTheme.ink : AppTheme.mutedTint)
            .monospacedDigit().multilineTextAlignment(.trailing)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(entry.hasData ? "Заявок: \(entry.value ?? 0)" : "Нет данных")
    }
    @ViewBuilder private var rank: some View {
        if let rank = entry.rank, (1...3).contains(rank) {
            Image(systemName: "medal.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(medalColor(rank), AppTheme.primaryTint)
                .font(.system(size: 32))
                .accessibilityLabel("\(rank) место")
        } else {
            Text(entry.rank.map(String.init) ?? "—")
                .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.mutedTint).monospacedDigit()
        }
    }
    private func medalColor(_ rank: Int) -> Color {
        switch rank { case 1: Color(red: 0.91, green: 0.69, blue: 0.18); case 2: Color(red: 0.66, green: 0.70, blue: 0.76); default: Color(red: 0.73, green: 0.43, blue: 0.23) }
    }
}
