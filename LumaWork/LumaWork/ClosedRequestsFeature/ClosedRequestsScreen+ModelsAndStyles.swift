import Foundation
import SwiftUI
import UIKit

extension ClosedRequestsScreen {
    typealias SearchEntry = ClosedRequestPreparedSearchEntry
    typealias ClosedRequestDayGroup = ClosedRequestPreparedDayGroup
    typealias ClosedRequestListItem = ClosedRequestPreparedListItem

    struct ClosedRequestsDateRangeSelection: Identifiable {
        let id = UUID()
        let availableRange: ClosedRange<Date>
        let selectedRange: ClosedRange<Date>
    }

    struct ActiveRequestListItem: Identifiable {
        let record: SimpleOneRequestRecord
        let incomingNumber: String
        let requestType: String
        let customer: String
        let address: String
        let terminalID: String
        var merchantTIN: String
        let information: String
        let statusText: String
        let isStatusRefreshing: Bool
        let registeredAtText: String?
        let deadlineText: String?
        let slaStatusText: String?
        let isOverdue: Bool
        let registeredSortDate: Date?
        let deadlineSortDate: Date?
        let searchText: String
        let matchingStatusFilters: Set<ActiveRequestsStatusFilter>

        var id: String {
            record.id
        }
    }

    struct SimpleOneActiveRequestCardContainer<Content: View>: View {
        let statusText: String
        let statusStyle: SimpleOneMulticardStatusStyle
        let isStatusRefreshing: Bool
        let content: Content
        private let cardFill = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.15, blue: 0.16, alpha: 1)
                : UIColor.white
        })

        init(
            statusText: String,
            statusStyle: SimpleOneMulticardStatusStyle,
            isStatusRefreshing: Bool = false,
            @ViewBuilder content: () -> Content
        ) {
            self.statusText = statusText
            self.statusStyle = statusStyle
            self.isStatusRefreshing = isStatusRefreshing
            self.content = content()
        }

        var body: some View {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(height: 8)

                    Group {
                        if isStatusRefreshing {
                            SimpleOneStatusShimmerText(text: statusText)
                        } else {
                            Text(statusText)
                                .font(.caption.weight(.semibold))
                        }
                    }
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(statusStyle.foreground)
                        .frame(height: 50, alignment: .center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .offset(y: 12)
                }
                .frame(height: 58)
                .frame(maxWidth: .infinity)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 28,
                        bottomTrailingRadius: 28,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                        .fill(statusStyle.background)
                )
                .offset(y: 26)
                .zIndex(0)

                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
                .shadow(color: AppTheme.shadow.opacity(0.85), radius: 12, x: 0, y: 7)
                .zIndex(1)
            }
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    struct SimpleOneStatusShimmerText: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let text: String
        @State private var startedAt = Date()

        var body: some View {
            label
                .foregroundStyle(.white.opacity(0.58))
                .overlay {
                    TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 30.0 : nil)) { timeline in
                        GeometryReader { geometry in
                            shimmerBand(
                                size: geometry.size,
                                progress: shimmerProgress(at: timeline.date)
                            )
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    startedAt = Date()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityValue("Обновление данных")
        }

        private var label: some View {
            Text(text)
                .font(.caption.weight(.semibold))
        }

        private func shimmerBand(size: CGSize, progress: CGFloat) -> some View {
            let bandWidth = max(size.width * 0.48, 24)
            let bandHeight = max(size.height * 3, 1)
            let overflow = size.height
            let travelDistance = size.width + bandWidth + overflow * 2

            return LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.white.opacity(0.2), location: 0.3),
                    .init(color: .white, location: 0.5),
                    .init(color: Color.white.opacity(0.2), location: 0.7),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth, height: bandHeight)
            .rotationEffect(.degrees(-45))
            .offset(
                x: -bandWidth - overflow + travelDistance * progress,
                y: (size.height - bandHeight) / 2
            )
        }

        private func shimmerProgress(at date: Date) -> CGFloat {
            let duration = reduceMotion ? 1.8 : 1.15
            let elapsed = max(date.timeIntervalSince(startedAt), 0)
            return CGFloat(elapsed.truncatingRemainder(dividingBy: duration) / duration)
        }
    }

    struct SimpleOneStatusBandShape: Shape {
        var topLift: CGFloat
        var cornerRadius: CGFloat

        func path(in rect: CGRect) -> Path {
            let lift = min(topLift, rect.height * 0.45)
            let radius = min(cornerRadius, rect.width / 2, rect.height)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: lift))
            path.addQuadCurve(
                to: CGPoint(x: lift, y: 0),
                control: CGPoint(x: 0, y: 0)
            )
            path.addLine(to: CGPoint(x: rect.maxX - lift, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: lift),
                control: CGPoint(x: rect.maxX, y: 0)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: rect.maxY - radius),
                control: CGPoint(x: 0, y: rect.maxY)
            )
            path.closeSubpath()
            return path
        }
    }

    struct SimpleOneMulticardStatusStyle {
        let background: Color
        let foreground: Color

        static func status(_ raw: String) -> SimpleOneMulticardStatusStyle {
            let value = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if value.contains("ожидан") || value.contains("waiting") || value.contains("pending") {
                return SimpleOneMulticardStatusStyle(
                    background: Color(red: 0.95, green: 0.55, blue: 0.11),
                    foreground: Color(red: 0.17, green: 0.11, blue: 0.03)
                )
            }
            return SimpleOneMulticardStatusStyle(
                background: Color(red: 0.74, green: 0.20, blue: 0.18),
                foreground: .white
            )
        }

        static let loading = SimpleOneMulticardStatusStyle(
            background: Color(red: 0.34, green: 0.38, blue: 0.42),
            foreground: .white
        )

        static func closedStatus(_ raw: String) -> SimpleOneMulticardStatusStyle {
            let value = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if value.contains("ожидан") || value.contains("waiting") || value.contains("pending") {
                return SimpleOneMulticardStatusStyle(
                    background: Color(red: 0.95, green: 0.55, blue: 0.11),
                    foreground: Color(red: 0.17, green: 0.11, blue: 0.03)
                )
            }
            if value.contains("выполн") || value.contains("закрыт") || value.contains("done") || value.contains("closed") {
                return SimpleOneMulticardStatusStyle(
                    background: Color(red: 0.12, green: 0.43, blue: 0.78),
                    foreground: .white
                )
            }
            if value.contains("работ") || value.contains("progress") || value.contains("active") {
                return SimpleOneMulticardStatusStyle(
                    background: Color(red: 0.04, green: 0.48, blue: 0.19),
                    foreground: .white
                )
            }
            if value.contains("отказ") || value.contains("отклон") || value.contains("cancel") || value.contains("reject") {
                return SimpleOneMulticardStatusStyle(
                    background: Color(red: 0.74, green: 0.20, blue: 0.18),
                    foreground: .white
                )
            }
            return SimpleOneMulticardStatusStyle(
                background: Color(red: 0.34, green: 0.38, blue: 0.42),
                foreground: .white
            )
        }
    }

    struct RequestChip: View {
        let text: String
        let style: RequestChipStyle

        var body: some View {
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(style.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(style.background, in: Capsule())
        }
    }

    struct RequestChipStyle {
        let background: Color
        let foreground: Color

        static func status(_ raw: String) -> RequestChipStyle {
            let value = normalized(raw)
            if value.contains("ожидан") || value.contains("waiting") || value.contains("pending") {
                return RequestChipStyle(
                    background: Color(red: 0.95, green: 0.55, blue: 0.11),
                    foreground: Color(red: 0.17, green: 0.11, blue: 0.03)
                )
            }
            if value.contains("работ") || value.contains("progress") || value.contains("active") {
                return RequestChipStyle(
                    background: Color(red: 0.04, green: 0.48, blue: 0.19),
                    foreground: .white
                )
            }
            if value.contains("выполн") || value.contains("закрыт") || value.contains("done") || value.contains("closed") {
                return RequestChipStyle(
                    background: Color(red: 0.12, green: 0.43, blue: 0.78),
                    foreground: .white
                )
            }
            if value.contains("отказ") || value.contains("отклон") || value.contains("cancel") || value.contains("reject") {
                return RequestChipStyle(
                    background: Color(red: 0.74, green: 0.20, blue: 0.18),
                    foreground: .white
                )
            }
            if value.contains("нов") || value.contains("new") {
                return RequestChipStyle(
                    background: Color(red: 0.25, green: 0.45, blue: 0.86),
                    foreground: .white
                )
            }
            return RequestChipStyle(
                background: AppTheme.mutedTint.opacity(0.22),
                foreground: AppTheme.ink
            )
        }

        static func requestType(_ raw: String) -> RequestChipStyle {
            let value = normalized(raw)
            if value.contains("установ") || value.contains("install") {
                return RequestChipStyle(
                    background: Color(red: 0.14, green: 0.52, blue: 0.34),
                    foreground: .white
                )
            }
            if value.contains("демонтаж") || value.contains("dismount") {
                return RequestChipStyle(
                    background: Color(red: 0.72, green: 0.25, blue: 0.24),
                    foreground: .white
                )
            }
            if value.contains("возврат") || value.contains("return") {
                return RequestChipStyle(
                    background: Color(red: 0.82, green: 0.42, blue: 0.13),
                    foreground: .white
                )
            }
            if value.contains("сервис") || value.contains("service") {
                return RequestChipStyle(
                    background: Color(red: 0.18, green: 0.42, blue: 0.78),
                    foreground: .white
                )
            }
            if value.contains("замен") || value.contains("replacement") {
                return RequestChipStyle(
                    background: Color(red: 0.46, green: 0.32, blue: 0.72),
                    foreground: .white
                )
            }
            return RequestChipStyle(
                background: Color(red: 0.34, green: 0.38, blue: 0.42),
                foreground: .white
            )
        }

        private static func normalized(_ raw: String) -> String {
            raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
    }

    func normalizedAddress(_ raw: String) -> String {
        raw.normalizedAddressStartingFromAlushta()
    }
}
