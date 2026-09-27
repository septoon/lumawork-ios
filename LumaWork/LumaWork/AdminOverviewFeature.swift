import Foundation
import Observation
import SwiftUI

struct AdminOverviewSnapshot: Equatable {
    var system: AdminOverviewSystem
    var resources: AdminOverviewVPSResources?
    var stats: AdminOverviewStats
    var storage: AdminOverviewStorage
    var dataStorage: AdminOverviewDataStorage?
    var recentActions: [AdminAuditAction]
}

struct AdminOverviewSystem: Equatable {
    var service: String
    var status: String
    var serverTime: Date?
    var startedAt: Date?
    var uptimeSeconds: Int64
    var nodeVersion: String
    var memoryResidentBytes: Int64

    var isHealthy: Bool {
        ["ok", "healthy", "online", "up", "ready"].contains(status.lowercased())
    }
}

struct AdminOverviewStats: Equatable {
    var users: Int
    var admins: Int
    var blockedUsers: Int
    var activeUsers7d: Int
    var vehicles: Int
    var vehicleCatalogs: Int
    var missingVehicleImages: Int
    var pendingVehicleImages: Int
    var backpackBindings: Int
    var missingBackpackImages: Int
    var orphanImages: Int
}

struct AdminOverviewStorage: Equatable {
    var imageFiles: Int
    var bytes: Int64
}

struct AdminOverviewVPSResources: Equatable {
    var capturedAt: Date?
    var cpuUsagePercent: Double
    var cpuCores: Int
    var loadAverage1m: Double
    var ramUsedBytes: Int64
    var ramTotalBytes: Int64
    var ramAvailableBytes: Int64
    var ramUsagePercent: Double
    var diskUsedBytes: Int64
    var diskTotalBytes: Int64
    var diskAvailableBytes: Int64
    var diskUsagePercent: Double
}

struct AdminOverviewDataStorage: Equatable {
    var capturedAt: Date?
    var totalBytes: Int64
    var databaseBytes: Int64
    var filesBytes: Int64
    var uploadBytes: Int64
    var reportBytes: Int64
    var templateBytes: Int64
    var databaseBackupBytes: Int64
    var attributedUserBytes: Int64
    var attributedFileBytes: Int64
    var unattributedFileBytes: Int64
    var usersVisible: Bool
    var users: [AdminOverviewUserStorage]
}

struct AdminOverviewUserStorage: Identifiable, Equatable {
    var id: String { userID }

    var userID: String
    var email: String
    var displayName: String
    var databaseBytes: Int64
    var fileBytes: Int64
    var totalBytes: Int64
    var recordCount: Int
    var fileCount: Int
}

struct AdminAuditAction: Identifiable, Equatable {
    var id: String
    var actorEmail: String
    var action: String
    var targetType: String
    var targetID: String?
    var summary: String?
    var createdAt: Date?
}

@MainActor
struct AdminOverviewAPI {
    private let baseURL: URL
    private let http = HTTPClient()

    init(config: AppConfig) {
        baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)
    }

    func fetch(token: String) async throws -> AdminOverviewSnapshot {
        let response = try await http.request(
            url(path: "/api/v2/admin/overview"),
            authToken: token
        )
        guard let root = adminOverviewDictionary(response.json) else {
            throw AppServiceError.message("Сервер не вернул данные админки.")
        }
        let payload = adminOverviewDictionary(root["overview"])
            ?? adminOverviewDictionary(root["data"])
            ?? root

        let systemRaw = adminOverviewDictionary(payload["system"]) ?? [:]
        let resourcesRaw = adminOverviewDictionary(payload["resources"])
        let statsRaw = adminOverviewDictionary(payload["stats"]) ?? [:]
        let storageRaw = adminOverviewDictionary(payload["storage"]) ?? [:]
        let dataStorageRaw = adminOverviewDictionary(payload["dataStorage"] ?? payload["data_storage"])
        let actionsRaw = adminOverviewArray(payload["recentActions"] ?? payload["recent_actions"])

        let system = AdminOverviewSystem(
            service: adminOverviewString(systemRaw, keys: ["service", "name"]),
            status: adminOverviewString(systemRaw, keys: ["status", "state"], fallback: "unknown"),
            serverTime: adminOverviewDate(systemRaw["serverTime"] ?? systemRaw["server_time"]),
            startedAt: adminOverviewDate(systemRaw["startedAt"] ?? systemRaw["started_at"]),
            uptimeSeconds: adminOverviewInt64(systemRaw["uptimeSeconds"] ?? systemRaw["uptime_seconds"]),
            nodeVersion: adminOverviewString(systemRaw, keys: ["nodeVersion", "node_version"]),
            memoryResidentBytes: adminOverviewInt64(
                systemRaw["memoryResidentBytes"] ?? systemRaw["memory_resident_bytes"]
            )
        )
        let resources = resourcesRaw.map {
            AdminOverviewVPSResources(
                capturedAt: adminOverviewDate($0["capturedAt"] ?? $0["captured_at"]),
                cpuUsagePercent: adminOverviewDouble($0["cpuUsagePercent"] ?? $0["cpu_usage_percent"]),
                cpuCores: adminOverviewInt($0["cpuCores"] ?? $0["cpu_cores"]),
                loadAverage1m: adminOverviewDouble($0["loadAverage1m"] ?? $0["load_average_1m"]),
                ramUsedBytes: adminOverviewInt64($0["ramUsedBytes"] ?? $0["ram_used_bytes"]),
                ramTotalBytes: adminOverviewInt64($0["ramTotalBytes"] ?? $0["ram_total_bytes"]),
                ramAvailableBytes: adminOverviewInt64($0["ramAvailableBytes"] ?? $0["ram_available_bytes"]),
                ramUsagePercent: adminOverviewDouble($0["ramUsagePercent"] ?? $0["ram_usage_percent"]),
                diskUsedBytes: adminOverviewInt64($0["diskUsedBytes"] ?? $0["disk_used_bytes"]),
                diskTotalBytes: adminOverviewInt64($0["diskTotalBytes"] ?? $0["disk_total_bytes"]),
                diskAvailableBytes: adminOverviewInt64($0["diskAvailableBytes"] ?? $0["disk_available_bytes"]),
                diskUsagePercent: adminOverviewDouble($0["diskUsagePercent"] ?? $0["disk_usage_percent"])
            )
        }
        let stats = AdminOverviewStats(
            users: adminOverviewInt(statsRaw["users"]),
            admins: adminOverviewInt(statsRaw["admins"]),
            blockedUsers: adminOverviewInt(statsRaw["blockedUsers"] ?? statsRaw["blocked_users"]),
            activeUsers7d: adminOverviewInt(statsRaw["activeUsers7d"] ?? statsRaw["active_users_7d"]),
            vehicles: adminOverviewInt(statsRaw["vehicles"]),
            vehicleCatalogs: adminOverviewInt(statsRaw["vehicleCatalogs"] ?? statsRaw["vehicle_catalogs"]),
            missingVehicleImages: adminOverviewInt(
                statsRaw["missingVehicleImages"] ?? statsRaw["missing_vehicle_images"]
            ),
            pendingVehicleImages: adminOverviewInt(
                statsRaw["pendingVehicleImages"] ?? statsRaw["pending_vehicle_images"]
            ),
            backpackBindings: adminOverviewInt(statsRaw["backpackBindings"] ?? statsRaw["backpack_bindings"]),
            missingBackpackImages: adminOverviewInt(
                statsRaw["missingBackpackImages"] ?? statsRaw["missing_backpack_images"]
            ),
            orphanImages: adminOverviewInt(statsRaw["orphanImages"] ?? statsRaw["orphan_images"])
        )
        let storage = AdminOverviewStorage(
            imageFiles: adminOverviewInt(storageRaw["imageFiles"] ?? storageRaw["image_files"]),
            bytes: adminOverviewInt64(storageRaw["bytes"])
        )
        let dataStorage = dataStorageRaw.map { raw in
            let users = adminOverviewArray(raw["users"]).map { userRaw in
                AdminOverviewUserStorage(
                    userID: adminOverviewString(userRaw, keys: ["userId", "user_id", "id"]),
                    email: adminOverviewString(userRaw, keys: ["email"]),
                    displayName: adminOverviewString(userRaw, keys: ["displayName", "display_name", "email"]),
                    databaseBytes: adminOverviewInt64(userRaw["databaseBytes"] ?? userRaw["database_bytes"]),
                    fileBytes: adminOverviewInt64(userRaw["fileBytes"] ?? userRaw["file_bytes"]),
                    totalBytes: adminOverviewInt64(userRaw["totalBytes"] ?? userRaw["total_bytes"]),
                    recordCount: adminOverviewInt(userRaw["recordCount"] ?? userRaw["record_count"]),
                    fileCount: adminOverviewInt(userRaw["fileCount"] ?? userRaw["file_count"])
                )
            }
            .filter { !$0.userID.isEmpty }
            .sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                return $0.email.localizedStandardCompare($1.email) == .orderedAscending
            }

            return AdminOverviewDataStorage(
                capturedAt: adminOverviewDate(raw["capturedAt"] ?? raw["captured_at"]),
                totalBytes: adminOverviewInt64(raw["totalBytes"] ?? raw["total_bytes"]),
                databaseBytes: adminOverviewInt64(raw["databaseBytes"] ?? raw["database_bytes"]),
                filesBytes: adminOverviewInt64(raw["filesBytes"] ?? raw["files_bytes"]),
                uploadBytes: adminOverviewInt64(raw["uploadBytes"] ?? raw["upload_bytes"]),
                reportBytes: adminOverviewInt64(raw["reportBytes"] ?? raw["report_bytes"]),
                templateBytes: adminOverviewInt64(raw["templateBytes"] ?? raw["template_bytes"]),
                databaseBackupBytes: adminOverviewInt64(
                    raw["databaseBackupBytes"] ?? raw["database_backup_bytes"]
                ),
                attributedUserBytes: adminOverviewInt64(
                    raw["attributedUserBytes"] ?? raw["attributed_user_bytes"]
                ),
                attributedFileBytes: adminOverviewInt64(
                    raw["attributedFileBytes"] ?? raw["attributed_file_bytes"]
                ),
                unattributedFileBytes: adminOverviewInt64(
                    raw["unattributedFileBytes"] ?? raw["unattributed_file_bytes"]
                ),
                usersVisible: adminOverviewBool(raw["usersVisible"] ?? raw["users_visible"]),
                users: users
            )
        }
        let actions = actionsRaw.compactMap(AdminAuditAction.init(raw:)).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }

        return AdminOverviewSnapshot(
            system: system,
            resources: resources,
            stats: stats,
            storage: storage,
            dataStorage: dataStorage,
            recentActions: actions
        )
    }

    private func url(path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class AdminOverviewStore {
    private let api: AdminOverviewAPI
    private let token: String?

    var snapshot: AdminOverviewSnapshot?
    var isLoading = false
    var errorMessage: String?
    var lastUpdatedAt: Date?

    init(token: String?, api: AdminOverviewAPI? = nil) {
        self.token = token
        self.api = api ?? AdminOverviewAPI(config: AppConfig())
    }

    func loadIfNeeded() async {
        guard snapshot == nil else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            snapshot = try await api.fetch(token: token)
            lastUpdatedAt = Date()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }
}

enum AdminOverviewPage {
    case system
    case storage
    case metrics
    case audit

    var title: String {
        switch self {
        case .system: "Состояние системы"
        case .storage: "Хранилище данных"
        case .metrics: "Показатели"
        case .audit: "Журнал действий"
        }
    }
}

struct AdminOverviewDetailScreen: View {
    let store: AdminOverviewStore
    let permissions: Set<AdminPermission>
    let page: AdminOverviewPage

    var body: some View {
        AppScreen {
            if let errorMessage = store.errorMessage {
                AppNoticeBanner(text: errorMessage, tint: AppTheme.dangerTint, isCritical: true)
            }

            if let snapshot = store.snapshot {
                pageContent(snapshot: snapshot)
            } else if store.isLoading {
                AppLoadingView(title: "Проверяю состояние сервера")
            } else {
                AppEmptyState(
                    title: "Сводка недоступна",
                    message: "Обновите экран, чтобы повторить запрос.",
                    systemName: "gauge.with.dots.needle.50percent"
                )
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить сводку админки")
            }
        }
        .refreshable {
            await store.refresh()
        }
        .task {
            await store.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func pageContent(snapshot: AdminOverviewSnapshot) -> some View {
        switch page {
        case .system:
            AdminSystemHealthCard(system: snapshot.system, updatedAt: store.lastUpdatedAt)

            if let resources = snapshot.resources {
                AdminVPSResourcesCard(resources: resources)
            }

        case .storage:
            if let dataStorage = snapshot.dataStorage {
                AdminOverviewDataStorageCard(
                    dataStorage: dataStorage,
                    imageStorage: snapshot.storage,
                    orphanImages: snapshot.stats.orphanImages
                )

                if permissions.contains(.viewUsers), dataStorage.usersVisible {
                    AdminOverviewUserStorageSection(users: dataStorage.users)
                }
            } else {
                AdminOverviewLegacyStorageCard(
                    storage: snapshot.storage,
                    orphanImages: snapshot.stats.orphanImages
                )
            }

        case .metrics:
            AdminOverviewUsersSection(stats: snapshot.stats)
            AdminOverviewAssetsSection(stats: snapshot.stats)

        case .audit:
            AdminRecentAuditSection(actions: snapshot.recentActions)
        }
    }
}

private struct AdminSystemHealthCard: View {
    let system: AdminOverviewSystem
    let updatedAt: Date?

    private var tint: Color {
        system.isHealthy ? .green : AppTheme.dangerTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: system.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(system.isHealthy ? "Система работает" : "Требуется внимание")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(system.service.isEmpty ? "LumaWork API" : system.service)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedTint)
                }

                Spacer(minLength: 8)

                Text(system.status.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12), in: Capsule())
            }

            Divider()

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                systemFact("Аптайм", value: adminOverviewDuration(system.uptimeSeconds), icon: "clock.arrow.circlepath")
                systemFact("RSS API", value: adminOverviewBytes(system.memoryResidentBytes), icon: "memorychip")
                systemFact("Node.js", value: system.nodeVersion.nilIfAdminOverviewBlank ?? "—", icon: "chevron.left.forwardslash.chevron.right")
                systemFact("Время сервера", value: adminOverviewTime(system.serverTime), icon: "server.rack")
            }

            if let updatedAt {
                Text("Обновлено \(adminOverviewRelativeTime(updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.13), AppTheme.softFill.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private func systemFact(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 27, height: 27)
                .background(AppTheme.primaryTint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AdminVPSResourcesCard: View {
    let resources: AdminOverviewVPSResources

    var body: some View {
        AppSectionHeader(title: "Ресурсы VPS", caption: "Текущая нагрузка всего сервера")
        AppCard {
            resourceRow(
                title: "CPU",
                systemImage: "cpu",
                usagePercent: resources.cpuUsagePercent,
                detail: "CPU: \(resources.cpuCores.formatted()) • load \(adminOverviewDecimal(resources.loadAverage1m))"
            )

            Divider()

            resourceRow(
                title: "RAM",
                systemImage: "memorychip.fill",
                usagePercent: resources.ramUsagePercent,
                detail: "\(adminOverviewBytes(resources.ramUsedBytes)) из \(adminOverviewBytes(resources.ramTotalBytes)) • свободно \(adminOverviewBytes(resources.ramAvailableBytes))"
            )

            Divider()

            resourceRow(
                title: "SSD",
                systemImage: "internaldrive.fill",
                usagePercent: resources.diskUsagePercent,
                detail: "\(adminOverviewBytes(resources.diskUsedBytes)) из \(adminOverviewBytes(resources.diskTotalBytes)) • свободно \(adminOverviewBytes(resources.diskAvailableBytes))"
            )

            if let capturedAt = resources.capturedAt {
                Text("Снимок \(adminOverviewRelativeTime(capturedAt))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func resourceRow(
        title: String,
        systemImage: String,
        usagePercent: Double,
        detail: String
    ) -> some View {
        let tint = adminOverviewUsageTint(usagePercent)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                Text(adminOverviewPercent(usagePercent))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
            }

            ProgressView(value: min(max(usagePercent, 0), 100), total: 100)
                .tint(tint)
        }
    }
}

private struct AdminOverviewUsersSection: View {
    let stats: AdminOverviewStats

    var body: some View {
        AppSectionHeader(title: "Пользователи", caption: "Аккаунты и доступы")
        AdminOverviewMetricGrid(metrics: [
            .init(title: "Всего", value: stats.users, systemImage: "person.2.fill", tint: AppTheme.primaryTint),
            .init(title: "Администраторы", value: stats.admins, systemImage: "checkmark.shield.fill", tint: AppTheme.secondaryTint),
            .init(title: "Активны 7 дней", value: stats.activeUsers7d, systemImage: "bolt.fill", tint: .green),
            .init(title: "Заблокированы", value: stats.blockedUsers, systemImage: "lock.fill", tint: AppTheme.dangerTint)
        ])
    }
}

private struct AdminOverviewAssetsSection: View {
    let stats: AdminOverviewStats

    var body: some View {
        AppSectionHeader(title: "Изображения и авто", caption: "Каталоги, привязки и очередь")
        AdminOverviewMetricGrid(metrics: [
            .init(title: "Автомобили", value: stats.vehicles, systemImage: "car.fill", tint: AppTheme.primaryTint),
            .init(title: "Каталог авто", value: stats.vehicleCatalogs, systemImage: "photo.stack.fill", tint: AppTheme.secondaryTint),
            .init(title: "Без изображения", value: stats.missingVehicleImages, systemImage: "car.side.and.exclamationmark", tint: .orange),
            .init(title: "В очереди", value: stats.pendingVehicleImages, systemImage: "clock.badge.exclamationmark", tint: .orange),
            .init(title: "Привязки рюкзака", value: stats.backpackBindings, systemImage: "backpack.fill", tint: AppTheme.primaryTint),
            .init(title: "Нет фото терминала", value: stats.missingBackpackImages, systemImage: "photo.badge.exclamationmark", tint: .orange)
        ])
    }
}

private struct AdminOverviewMetric: Identifiable {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var id: String { title }
}

private struct AdminOverviewMetricGrid: View {
    let metrics: [AdminOverviewMetric]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 145), spacing: 12)],
            spacing: 12
        ) {
            ForEach(metrics) { metric in
                HStack(spacing: 11) {
                    Image(systemName: metric.systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(metric.tint)
                        .frame(width: 34, height: 34)
                        .background(metric.tint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.value.formatted())
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedTint)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(
                    AppTheme.cardSurface.opacity(0.84),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }
        }
    }
}

private struct AdminOverviewDataStorageCard: View {
    let dataStorage: AdminOverviewDataStorage
    let imageStorage: AdminOverviewStorage
    let orphanImages: Int

    var body: some View {
        AppSectionHeader(
            title: "Данные LumaWork",
            caption: "PostgreSQL, файлы, отчёты и резервные копии"
        )
        AppCard {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(adminOverviewBytes(dataStorage.totalBytes))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Постоянные данные приложения")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }

            Divider()
            AppStatRow(title: "PostgreSQL", value: adminOverviewBytes(dataStorage.databaseBytes))
            Divider()
            AppStatRow(title: "Все файлы", value: adminOverviewBytes(dataStorage.filesBytes))
            Divider()
            AppStatRow(title: "Uploads", value: adminOverviewBytes(dataStorage.uploadBytes))
            Divider()
            AppStatRow(title: "Отчёты ГСМ", value: adminOverviewBytes(dataStorage.reportBytes))
            Divider()
            AppStatRow(title: "Резервные копии БД", value: adminOverviewBytes(dataStorage.databaseBackupBytes))
            Divider()
            AppStatRow(
                title: "Общие и без владельца",
                value: adminOverviewBytes(dataStorage.unattributedFileBytes),
                accent: dataStorage.unattributedFileBytes > 0 ? .orange : AppTheme.ink
            )
            Divider()
            AppStatRow(
                title: "Изображения",
                value: "\(adminOverviewBytes(imageStorage.bytes)) • \(imageStorage.imageFiles.formatted()) шт."
            )

            if orphanImages > 0 {
                Divider()
                AppStatRow(title: "Изображения без привязок", value: orphanImages.formatted(), accent: .orange)
            }

            Text("Общий объём включает всю БД, uploads, отчёты и их backup, шаблоны ГСМ и резервные копии PostgreSQL.")
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdminOverviewUserStorageSection: View {
    let users: [AdminOverviewUserStorage]

    var body: some View {
        AppSectionHeader(
            title: "Данные пользователей",
            caption: "Все связанные записи БД и атрибутируемые файлы"
        )

        if users.isEmpty {
            AppEmptyState(
                title: "Данных нет",
                message: "Пользовательские данные пока не занимают место на сервере.",
                systemName: "person.2.slash"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                    AdminOverviewUserStorageRow(user: user)
                    if index < users.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(
                AppTheme.cardSurface.opacity(0.84),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )

            Text("Размер БД рассчитан по всем строкам пользователя, включая JSON, маршруты, топливо, зарплату, сессии и отчёты. Физические индексы PostgreSQL и файлы без надёжного владельца показаны только в общем объёме.")
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdminOverviewUserStorageRow: View {
    let user: AdminOverviewUserStorage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 34, height: 34)
                .background(AppTheme.primaryTint.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName.nilIfAdminOverviewBlank ?? user.email)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                if user.displayName.caseInsensitiveCompare(user.email) != .orderedSame {
                    Text(user.email)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(1)
                }

                Text("БД \(adminOverviewBytes(user.databaseBytes)) • файлы \(adminOverviewBytes(user.fileBytes))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Записей: \(user.recordCount.formatted()) • файлов: \(user.fileCount.formatted())")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedTint)
            }

            Spacer(minLength: 8)

            Text(adminOverviewBytes(user.totalBytes))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct AdminOverviewLegacyStorageCard: View {
    let storage: AdminOverviewStorage
    let orphanImages: Int

    private var averageFileSize: Int64 {
        guard storage.imageFiles > 0 else { return 0 }
        return storage.bytes / Int64(storage.imageFiles)
    }

    var body: some View {
        AppSectionHeader(title: "Хранилище", caption: "Файлы изображений на сервере")
        AppCard {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.primaryTint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(adminOverviewBytes(storage.bytes))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Занято изображениями")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                }
            }

            Divider()
            AppStatRow(title: "Файлов", value: storage.imageFiles.formatted())
            Divider()
            AppStatRow(title: "Средний размер", value: adminOverviewBytes(averageFileSize))
            Divider()
            AppStatRow(
                title: "Без привязок",
                value: orphanImages.formatted(),
                accent: orphanImages > 0 ? .orange : AppTheme.ink
            )
        }
    }
}

private struct AdminRecentAuditSection: View {
    let actions: [AdminAuditAction]

    var body: some View {
        AppSectionHeader(
            title: "Последние действия",
            caption: actions.isEmpty ? "Журнал пока пуст" : "Недавние изменения в админке"
        )

        if actions.isEmpty {
            AppEmptyState(
                title: "Действий нет",
                message: "Новые административные изменения появятся здесь.",
                systemName: "checklist"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    AdminAuditActionRow(action: action)
                    if index < actions.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(
                AppTheme.cardSurface.opacity(0.84),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }
}

private struct AdminAuditActionRow: View {
    let action: AdminAuditAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: actionIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(actionTint)
                .frame(width: 32, height: 32)
                .background(actionTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)

                if let summary = action.summary?.nilIfAdminOverviewBlank {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(3)
                }

                HStack(spacing: 5) {
                    Text(action.actorEmail.nilIfAdminOverviewBlank ?? "Система")
                    if let target = targetDescription {
                        Text("•")
                        Text(target)
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(adminOverviewRelativeTime(action.createdAt))
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedTint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var normalizedAction: String {
        action.action
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
    }

    private var actionTitle: String {
        switch normalizedAction {
        case "USER_BLOCK", "USER_BLOCKED": "Пользователь заблокирован"
        case "USER_UNBLOCK", "USER_UNBLOCKED": "Пользователь разблокирован"
        case "USER_ACCESS_UPDATE", "USER_ACCESS_UPDATED": "Изменены роль и права"
        case "USER_DELETE", "USER_DELETED": "Удалён пользователь"
        case "IMAGE_CREATE", "IMAGE_CREATED", "IMAGE_BINDING_CREATE": "Добавлена привязка изображения"
        case "IMAGE_UPLOAD": "Загружено изображение"
        case "IMAGE_UPDATE", "IMAGE_UPDATED", "IMAGE_REPLACE", "IMAGE_REPLACED", "IMAGE_METADATA_UPDATE": "Обновлено изображение"
        case "IMAGE_DELETE", "IMAGE_DELETED": "Удалено изображение"
        case "VEHICLE_IMAGE_PREPARE": "Подготовлена позиция автомобиля"
        case "VEHICLE_IMAGE_REQUEST_START": "Начата подготовка изображения"
        case "VEHICLE_IMAGE_REQUEST_REJECT": "Изображение автомобиля отклонено"
        default: action.action.nilIfAdminOverviewBlank ?? "Административное действие"
        }
    }

    private var actionIcon: String {
        if normalizedAction.contains("DELETE") { return "trash.fill" }
        if normalizedAction.contains("BLOCK") { return "lock.fill" }
        if normalizedAction.contains("IMAGE") { return "photo.fill" }
        if normalizedAction.contains("ACCESS") || normalizedAction.contains("PERMISSION") {
            return "checkmark.shield.fill"
        }
        return "person.crop.circle.badge.checkmark"
    }

    private var actionTint: Color {
        if normalizedAction.contains("DELETE") || normalizedAction.contains("BLOCK") {
            return AppTheme.dangerTint
        }
        if normalizedAction.contains("IMAGE") { return AppTheme.secondaryTint }
        return AppTheme.primaryTint
    }

    private var targetDescription: String? {
        let type = action.targetType.nilIfAdminOverviewBlank
        let id = action.targetID?.nilIfAdminOverviewBlank
        if let type, let id { return "\(type): \(id)" }
        return type ?? id
    }
}

private extension AdminAuditAction {
    init?(raw: [String: Any]) {
        let action = adminOverviewString(raw, keys: ["action"])
        guard !action.isEmpty else { return nil }

        let createdAt = adminOverviewDate(raw["createdAt"] ?? raw["created_at"])
        let providedID = adminOverviewString(raw, keys: ["id"])
        id = providedID.isEmpty
            ? "\(action)-\(createdAt?.timeIntervalSince1970 ?? 0)-\(adminOverviewString(raw, keys: ["targetId", "target_id"]))"
            : providedID
        actorEmail = adminOverviewString(raw, keys: ["actorEmail", "actor_email"])
        self.action = action
        targetType = adminOverviewString(raw, keys: ["targetType", "target_type"])
        targetID = adminOverviewString(raw, keys: ["targetId", "target_id"]).nilIfAdminOverviewBlank
        summary = adminOverviewString(raw, keys: ["summary"]).nilIfAdminOverviewBlank
        self.createdAt = createdAt
    }
}

private func adminOverviewDictionary(_ raw: Any?) -> [String: Any]? {
    raw as? [String: Any]
}

private func adminOverviewArray(_ raw: Any?) -> [[String: Any]] {
    if let array = raw as? [[String: Any]] { return array }
    if let array = raw as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    return []
}

private func adminOverviewString(
    _ raw: [String: Any],
    keys: [String],
    fallback: String = ""
) -> String {
    for key in keys {
        if let value = raw[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = raw[key] as? NSNumber { return value.stringValue }
    }
    return fallback
}

private func adminOverviewInt(_ raw: Any?) -> Int {
    if let value = raw as? Int { return value }
    if let value = raw as? NSNumber { return value.intValue }
    if let value = raw as? String { return Int(value) ?? 0 }
    return 0
}

private func adminOverviewInt64(_ raw: Any?) -> Int64 {
    if let value = raw as? Int64 { return value }
    if let value = raw as? NSNumber { return value.int64Value }
    if let value = raw as? String { return Int64(value) ?? 0 }
    return 0
}

private func adminOverviewDouble(_ raw: Any?) -> Double {
    if let value = raw as? Double { return value }
    if let value = raw as? NSNumber { return value.doubleValue }
    if let value = raw as? String { return Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    return 0
}

private func adminOverviewBool(_ raw: Any?) -> Bool {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
        return ["true", "1", "yes"].contains(value.lowercased())
    }
    return false
}

private func adminOverviewDate(_ raw: Any?) -> Date? {
    if let date = raw as? Date { return date }
    if let number = raw as? NSNumber {
        let value = number.doubleValue
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    guard let value = raw as? String else { return nil }
    for formatter in AdminOverviewDateFormatters.iso {
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

private func adminOverviewBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 Б" }
    return AdminOverviewFormatters.bytes.string(fromByteCount: bytes)
}

private func adminOverviewPercent(_ value: Double) -> String {
    "\(adminOverviewDecimal(value))%"
}

private func adminOverviewDecimal(_ value: Double) -> String {
    AdminOverviewFormatters.decimal.string(from: NSNumber(value: value)) ?? "0"
}

private func adminOverviewUsageTint(_ value: Double) -> Color {
    if value >= 90 { return AppTheme.dangerTint }
    if value >= 75 { return .orange }
    return .green
}

private func adminOverviewDuration(_ seconds: Int64) -> String {
    guard seconds > 0 else { return "—" }
    return AdminOverviewFormatters.duration.string(from: TimeInterval(seconds)) ?? "—"
}

private func adminOverviewTime(_ date: Date?) -> String {
    guard let date else { return "—" }
    return AdminOverviewFormatters.date.string(from: date)
}

private func adminOverviewRelativeTime(_ date: Date?) -> String {
    guard let date else { return "—" }
    return AdminOverviewFormatters.relative.localizedString(for: date, relativeTo: Date())
}

private extension String {
    var nilIfAdminOverviewBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum AdminOverviewDateFormatters {
    static let iso: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()
}

private enum AdminOverviewFormatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()

    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocale.russian
        formatter.unitsStyle = .short
        return formatter
    }()

    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = AppLocale.russian
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}
