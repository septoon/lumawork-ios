import SwiftUI

struct ClosedRequestsAnalyticsScreen: View {
    let snapshot: ClosedRequestsSnapshot?
    let records: [ClosedRequestRecord]
    let leaderboardStore: LeaderboardStore
    let leaderboardAccess: LeaderboardAccessStore
    let sourceUserID: String
    var showsCloseButton = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.statistics
    @State private var cityPicker = false

    private enum Mode: String, CaseIterable { case statistics = "Статистика", leaderboard = "Рейтинг" }

    var body: some View {
        Group {
            if leaderboardAccess.isEnabled { rankingContainer }
            else {
                ClosedRequestsAnalyticsContent(snapshot: snapshot, records: records, showsCloseButton: showsCloseButton)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await leaderboardAccess.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled else { return }
                await leaderboardAccess.refresh()
            }
        }
        .onChange(of: leaderboardAccess.isEnabled) { _, enabled in
            if !enabled { mode = .statistics; cityPicker = false; leaderboardStore.hide() }
        }
    }

    private var rankingContainer: some View {
        ZStack {
            ClosedRequestsAnalyticsContent(snapshot: snapshot, records: records, showsCloseButton: false, showsNavigationHeader: false)
                .opacity(mode == .statistics ? 1 : 0)
                .allowsHitTesting(mode == .statistics)
                .accessibilityHidden(mode != .statistics)
            LeaderboardContent(store: leaderboardStore)
                .opacity(mode == .leaderboard ? 1 : 0)
                .allowsHitTesting(mode == .leaderboard)
                .accessibilityHidden(mode != .leaderboard)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Режим аналитики", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(idealWidth: 210, maxWidth: 230)
            }
            if mode == .leaderboard {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { cityPicker = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                            Text(leaderboardStore.city.title).lineLimit(1).truncationMode(.tail)
                        }.font(.caption).frame(maxWidth: 86, minHeight: 44)
                    }
                    .accessibilityLabel("Город: \(leaderboardStore.city.title)")
                    .popover(isPresented: $cityPicker, arrowEdge: .top) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(leaderboardStore.availableCities) { city in
                                    Button {
                                        leaderboardStore.city = city; cityPicker = false
                                    } label: {
                                        HStack {
                                            Text(city.title)
                                            Spacer(minLength: 12)
                                            if leaderboardStore.city == city { Image(systemName: "checkmark") }
                                        }.padding(.horizontal, 16).frame(minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(leaderboardStore.city == city ? .isSelected : [])
                                }
                            }.padding(.vertical, 8)
                        }.frame(minWidth: 220, maxHeight: 420)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            } else if showsCloseButton {
                ToolbarItem(placement: .topBarTrailing) { ModalCloseButton(action: dismiss.callAsFunction) }
            }
        }
        .task(id: "\(mode.rawValue)|\(leaderboardStore.filterID)|\(sourceUserID)") {
            leaderboardStore.configure(sourceUserID: sourceUserID)
            if mode == .leaderboard { await leaderboardStore.show() } else { leaderboardStore.hide() }
        }
        .onDisappear { leaderboardStore.hide() }
    }
}
