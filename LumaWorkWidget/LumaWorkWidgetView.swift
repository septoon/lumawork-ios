import SwiftUI
import WidgetKit

struct LumaWorkWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: LumaWorkWidgetEntry

    var body: some View {
        Group {
            switch contentState {
            case .unavailable:
                WidgetMessageView(
                    systemImage: "arrow.clockwise",
                    title: "Нет данных",
                    message: "Откройте LumaWork для обновления"
                )
            case .signedOut:
                WidgetMessageView(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Требуется вход",
                    message: "Войдите в LumaWork"
                )
            case .empty(let snapshot):
                emptyView(snapshot)
            case .populated(let snapshot):
                if family == .systemMedium {
                    mediumView(snapshot)
                } else {
                    smallView(snapshot)
                }
            }
        }
        .widgetURL(AppRoute.requests.url)
    }

    private var contentState: ContentState {
        guard let snapshot = entry.snapshot else { return .unavailable }
        guard snapshot.isAuthenticated else { return .signedOut }
        guard snapshot.activeRequestCount > 0 else { return .empty(snapshot) }
        return .populated(snapshot)
    }

    private func emptyView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Заявки", systemImage: "checklist")
                .font(.headline)
            Spacer(minLength: 0)
            Text("Нет активных заявок")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            routeLine(snapshot.route)
            updatedText(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func smallView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Заявки")
                    .font(.headline)
                Spacer(minLength: 4)
                Text("\(snapshot.activeRequestCount)")
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())
            }

            if snapshot.overdueRequestCount > 0 {
                Label("Просрочено: \(snapshot.overdueRequestCount)", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Label("Без просрочек", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            if let request = snapshot.requests.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.number)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    requestDeadline(request)
                }
                .privacySensitive()
            }

            updatedText(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mediumView(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Заявки")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(snapshot.activeRequestCount)")
                        .font(.title.weight(.bold))
                    Text("активных")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot.overdueRequestCount > 0 {
                    Text("\(snapshot.overdueRequestCount) просрочено")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                updatedText(snapshot)
            }
            .frame(width: 86, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.requests.prefix(3)) { request in
                    Link(destination: AppRoute.request(id: request.id).url) {
                        RequestRow(request: request)
                    }
                    .buttonStyle(.plain)
                    .privacySensitive()
                }

                Spacer(minLength: 0)

                if let route = snapshot.route {
                    Link(destination: AppRoute.home.url) {
                        RouteRow(route: route)
                    }
                    .buttonStyle(.plain)
                    .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func routeLine(_ route: WidgetRouteSummary?) -> some View {
        if let route {
            Label("Маршрут \(route.completedStops)/\(route.totalStops)", systemImage: "map.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .privacySensitive()
        }
    }

    @ViewBuilder
    private func requestDeadline(_ request: WidgetRequestItem) -> some View {
        if let deadline = request.deadline {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(deadline, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(request.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        } else {
            Text(request.state)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func updatedText(_ snapshot: WidgetSnapshot) -> some View {
        Text("Обновлено \(snapshot.generatedAt, style: .relative)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private enum ContentState {
        case unavailable
        case signedOut
        case empty(WidgetSnapshot)
        case populated(WidgetSnapshot)
    }
}

private struct RequestRow: View {
    let request: WidgetRequestItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(request.isOverdue ? Color.red : Color.accentColor)
                .frame(width: 6, height: 6)
            Text(request.number)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 3)
            if let deadline = request.deadline {
                Text(deadline, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(request.isOverdue ? .red : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct RouteRow: View {
    let route: WidgetRouteSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: route.isSent ? "checkmark.circle.fill" : "map.fill")
                .foregroundStyle(route.isSent ? Color.green : Color.accentColor)
            Text(route.workType)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 3)
            Text(routeProgress(route))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func routeProgress(_ route: WidgetRouteSummary) -> String {
        let progress = "\(route.completedStops)/\(route.totalStops)"
        guard let distanceKm = route.distanceKm else { return progress }
        return "\(progress) · \(distanceKm) км"
    }
}

private struct WidgetMessageView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
