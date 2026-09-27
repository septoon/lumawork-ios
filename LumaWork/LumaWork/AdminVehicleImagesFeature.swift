import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit

enum EquipmentImageGenerationPrompt {
    static let placeholder = "[НАЗВАНИЕ И ТОЧНАЯ МОДЕЛЬ ОБОРУДОВАНИЯ]"

    static func text(for equipmentName: String) -> String {
        let name = equipmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return template.replacingOccurrences(of: placeholder, with: name.isEmpty ? placeholder : name)
    }

    static let template = """
    Создай высококачественное фотореалистичное каталожное изображение оборудования:

    [НАЗВАНИЕ И ТОЧНАЯ МОДЕЛЬ ОБОРУДОВАНИЯ]

    Изображение предназначено для раздела «Моё оборудование» мобильного приложения, поэтому объект должен выглядеть как аккуратный премиальный product render из официального каталога производителя.

    Точность оборудования

    Максимально точно воспроизведи реальный внешний вид указанной модели. Сохрани характерные для неё пропорции, форму корпуса, материалы, цвет, расположение кнопок, клавиатуры, портов, разъёмов, индикаторов, камер, датчиков, логотипов и других видимых элементов.

    Не придумывай несуществующие детали и не заменяй указанную модель похожим устройством. Если существует несколько модификаций, ориентируйся на наиболее типичный внешний вид именно указанной модели.

    Композиция

    Покажи одно устройство целиком.

    Используй выразительный каталожный ракурс 3/4 спереди, слегка сверху, чтобы одновременно хорошо читались передняя и боковая части устройства и его основные органы управления.

    Если для конкретного типа оборудования такой ракурс неестественен, выбери наиболее информативный аналогичный каталожный ракурс.

    Объект должен занимать примерно 80–90% полезной площади изображения, располагаться по центру и полностью помещаться в кадре. Ничего не обрезать.

    Не добавляй людей, руки, стол, интерьер, упаковку, кабели, аксессуары или декоративные предметы, если они не являются неотъемлемой частью самого устройства.

    Экран

    Если оборудование имеет дисплей, экран должен быть включён.

    К запросу может быть приложено отдельное изображение, предназначенное для экрана. В таком случае используй именно приложенное изображение как обои/изображение на дисплее устройства.

    Не перерисовывай и не переосмысливай эти обои. Сохрани исходную композицию, цвета, логотипы и остальные элементы изображения максимально точно. Разрешается только перспективное преобразование и кадрирование, необходимые для естественного размещения изображения внутри физической плоскости экрана.

    Экран должен выглядеть физически реалистично: правильная перспектива, умеренная яркость, естественные отражения стекла и соответствие освещению устройства.

    Если отдельное изображение для экрана не приложено — используй нейтральные минималистичные обои без текста, интерфейсов приложений и дополнительных логотипов.

    Свет и материалы

    Используй мягкое профессиональное студийное освещение. Материалы корпуса должны выглядеть физически достоверно: металл — как металл, матовый пластик — как пластик, стекло — как стекло.

    Добавь естественные мягкие блики и отражения, подчёркивающие форму устройства, но без чрезмерного глянца.

    Изображение должно быть очень чётким и детализированным, без искусственного CGI-вида.

    Фон и тень

    Итоговое изображение должно иметь настоящий прозрачный фон.

    Формат результата — PNG RGBA с альфа-каналом. Все фоновые пиксели должны иметь прозрачность alpha = 0.

    Не используй белый, серый, чёрный или цветной фон. Не рисуй шахматную сетку и не имитируй прозрачность.

    При этом обязательно сохрани под устройством мягкую реалистичную контактную тень. Тень должна плавно переходить в прозрачность и также находиться в RGBA-слое изображения. Она не должна выглядеть как отдельное серое пятно или подложка.

    Края устройства должны быть чистыми и естественными, без белого ореола, бахромы и следов удаления фона.

    Единый визуальный стиль

    Стиль изображения: современная официальная продуктовая фотография / premium e-commerce catalog render.

    Нейтральное освещение, реалистичные материалы, высокая детализация, чистая композиция, одинаковая визуальная подача для разных категорий оборудования.

    Не добавляй подписи, характеристики, название модели, декоративные рамки, карточки интерфейса или водяные знаки.

    Итог: одно реалистичное устройство, полностью помещающееся в кадре, ракурс 3/4, профессиональный каталожный свет, приложенное изображение на экране (если экран присутствует), прозрачный PNG-фон и мягкая естественная тень.
    """
}

enum AdminServerImageKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case userAvatar
    case vehicleCatalog
    case officeEquipment
    case backpackTerminal
    case system
    case orphan

    var id: String { rawValue }
    var title: String {
        switch self {
        case .userAvatar: "Аватары"
        case .vehicleCatalog: "Автомобили"
        case .officeEquipment: "Личное оборудование"
        case .backpackTerminal: "Терминалы в рюкзаке"
        case .system: "Системные"
        case .orphan: "Без связей"
        }
    }
    var systemImage: String {
        switch self {
        case .userAvatar: "person.crop.circle"
        case .vehicleCatalog: "car.side"
        case .officeEquipment: "desktopcomputer"
        case .backpackTerminal: "creditcard"
        case .system: "gearshape.2"
        case .orphan: "externaldrive.badge.exclamationmark"
        }
    }
}

struct AdminImageBinding: Codable, Hashable, Identifiable {
    var id: String { name + value }
    let name: String
    let value: String
}

struct AdminImageCapabilities: Codable, Hashable {
    let canUpload: Bool
    let canDelete: Bool
    let canEditMetadata: Bool
}

struct AdminServerImage: Codable, Hashable, Identifiable {
    let id: String
    let kind: AdminServerImageKind
    let title: String
    let subtitle: String?
    let purpose: String
    let imageUrl: URL?
    let path: String?
    let isMissing: Bool
    let usageCount: Int
    let sharedReferenceCount: Int
    let sizeBytes: Int?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let updatedAt: String?
    let bindings: [AdminImageBinding]
    let capabilities: AdminImageCapabilities
    let metadata: [String: String]
    let aliases: [String]

    var searchableText: String {
        ([title, subtitle ?? "", purpose, path ?? ""] + bindings.flatMap { [$0.name, $0.value] })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
            .lowercased()
    }
}

private struct AdminImagesResponse: Decodable {
    let images: [AdminServerImage]
}

private struct AdminCreatedImageBindingResponse: Decodable {
    struct Item: Decodable {
        let id: String
    }

    let item: Item
}

struct AdminImagesAPI {
    private let baseURL = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
    private let client = HTTPClient()

    func fetch(token: String) async throws -> [AdminServerImage] {
        let response = try await client.request(url("/api/v2/admin/images"), authToken: token)
        return try decode(AdminImagesResponse.self, from: response.json).images
    }

    func createCatalogImage(
        kind: AdminServerImageKind,
        referenceName: String,
        aliases: [String],
        token: String
    ) async throws -> String {
        let endpoint: String
        switch kind {
        case .officeEquipment:
            endpoint = "/api/v2/admin/images/equipment"
        case .backpackTerminal:
            endpoint = "/api/v2/admin/images/backpack-terminals"
        default:
            throw AppServiceError.message("Этот тип каталога нельзя создать вручную.")
        }
        let response = try await client.request(
            url(endpoint),
            method: "POST",
            body: ["referenceName": referenceName, "aliases": aliases],
            authToken: token
        )
        return try decode(AdminCreatedImageBindingResponse.self, from: response.json).item.id
    }

    func updateMetadata(_ image: AdminServerImage, body: [String: Any], token: String) async throws {
        _ = try await client.request(
            url("/api/v2/admin/images/\(image.kind.rawValue)/\(image.id)"),
            method: "PATCH",
            body: body,
            authToken: token
        )
    }

    func uploadChunk(
        image: AdminServerImage,
        uploadID: String,
        chunkIndex: Int,
        totalChunks: Int,
        data: Data,
        token: String
    ) async throws {
        _ = try await client.request(
            url("/api/v2/admin/images/\(image.kind.rawValue)/\(image.id)/image-chunk"),
            method: "POST",
            body: [
                "uploadId": uploadID,
                "chunkIndex": chunkIndex,
                "totalChunks": totalChunks,
                "chunkBase64": data.base64EncodedString()
            ],
            authToken: token
        )
    }

    func delete(_ image: AdminServerImage, token: String) async throws {
        _ = try await client.request(
            url("/api/v2/admin/images/\(image.kind.rawValue)/\(image.id)"),
            method: "DELETE",
            authToken: token
        )
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: Any?) throws -> Value {
        guard let json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(type, from: data)
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
@Observable
final class AdminImagesStore {
    private let api = AdminImagesAPI()
    private let token: String?

    var images: [AdminServerImage] = []
    var isLoading = false
    private(set) var hasLoaded = false
    var uploadingImageID: String?
    var uploadProgress: Double?
    var errorMessage: String?
    var notice: String?

    init(token: String?) {
        self.token = token
    }

    func load() async {
        guard let token, !token.isEmpty else {
            errorMessage = "Требуется авторизация администратора."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loadedImages = try await api.fetch(token: token)
            try Task.checkCancellation()
            images = loadedImages
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func createCatalogImage(
        kind: AdminServerImageKind,
        referenceName: String,
        aliases: [String],
        imageData: Data
    ) async -> Bool {
        guard let token else { return false }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }
        do {
            let normalizedName = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = images.first {
                $0.kind == kind
                    && $0.isMissing
                    && $0.title.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
            }
            let image: AdminServerImage
            if let existing {
                image = existing
            } else {
                let id = try await api.createCatalogImage(
                    kind: kind,
                    referenceName: normalizedName,
                    aliases: aliases,
                    token: token
                )
                images = try await api.fetch(token: token)
                guard let created = images.first(where: { $0.kind == kind && $0.id == id }) else {
                    throw AppServiceError.message("Запись создана, но сервер не вернул её в каталоге изображений.")
                }
                image = created
            }
            let uploaded = await upload(imageData, for: image)
            if uploaded {
                notice = kind == .officeEquipment
                    ? "Фото личного оборудования добавлено."
                    : "Фото терминала добавлено."
            }
            return uploaded
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func updateMetadata(_ image: AdminServerImage, body: [String: Any]) async -> Bool {
        guard let token else { return false }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }
        do {
            try await api.updateMetadata(image, body: body, token: token)
            notice = "Переменные изображения обновлены."
            images = try await api.fetch(token: token)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func upload(_ data: Data, for image: AdminServerImage) async -> Bool {
        guard let token else { return false }
        let chunkSize = 512 * 1024
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        let uploadID = UUID().uuidString.lowercased()
        uploadingImageID = image.id
        uploadProgress = 0
        errorMessage = nil
        notice = nil
        defer {
            uploadingImageID = nil
            uploadProgress = nil
        }
        do {
            for index in 0 ..< totalChunks {
                let lowerBound = index * chunkSize
                let upperBound = min(lowerBound + chunkSize, data.count)
                try await api.uploadChunk(
                    image: image,
                    uploadID: uploadID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    data: data.subdata(in: lowerBound ..< upperBound),
                    token: token
                )
                uploadProgress = Double(index + 1) / Double(totalChunks)
            }
            notice = image.isMissing ? "Изображение загружено." : "Изображение заменено."
            images = try await api.fetch(token: token)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }

    func delete(_ image: AdminServerImage) async -> Bool {
        guard let token else { return false }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }
        do {
            try await api.delete(image, token: token)
            notice = image.kind == .orphan
                ? "Неиспользуемый файл удалён."
                : (image.isMissing ? "Карточка удалена." : "Изображение удалено, привязка сохранена.")
            images = try await api.fetch(token: token)
            return true
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
            return false
        }
    }
}

private enum AdminImageSection: String, CaseIterable, Identifiable, Hashable {
    case all
    case userAvatars
    case vehicles
    case officeEquipment
    case backpackTerminals
    case service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все фотографии"
        case .userAvatars: "Пользовательские"
        case .vehicles: "Транспорт"
        case .officeEquipment: "Личное оборудование"
        case .backpackTerminals: "Терминалы в рюкзаке"
        case .service: "Прочие изображения"
        }
    }

    var caption: String {
        switch self {
        case .all: "Все изображения и файлы на сервере"
        case .userAvatars: "Аватары пользователей"
        case .vehicles: "Автомобили и очередь генерации"
        case .officeEquipment: "Модели и фотографии из SimpleOne"
        case .backpackTerminals: "Отдельный каталог терминалов рюкзака"
        case .service: "Аватары, placeholder и файлы без связей"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "photo.stack"
        case .userAvatars: "person.crop.circle"
        case .vehicles: "car.side"
        case .officeEquipment: "desktopcomputer"
        case .backpackTerminals: "creditcard"
        case .service: "photo.stack"
        }
    }

    var kinds: Set<AdminServerImageKind> {
        switch self {
        case .all: Set(AdminServerImageKind.allCases)
        case .userAvatars: [.userAvatar]
        case .vehicles: [.vehicleCatalog]
        case .officeEquipment: [.officeEquipment]
        case .backpackTerminals: [.backpackTerminal]
        case .service: [.system, .orphan]
        }
    }
}

private enum AdminImageSheetDestination: Identifiable, Hashable {
    case asset(AdminServerImage)
    case addCatalogImage(AdminServerImageKind)

    var id: String {
        switch self {
        case .asset(let image): "asset-\(image.kind.rawValue)-\(image.id)"
        case .addCatalogImage(let kind): "add-\(kind.rawValue)"
        }
    }
}

struct AdminImagesPanel: View {
    @State private var store: AdminImagesStore

    let token: String?
    let permissions: Set<AdminPermission>

    init(
        token: String?,
        permissions: Set<AdminPermission>
    ) {
        _store = State(initialValue: AdminImagesStore(token: token))
        self.token = token
        self.permissions = permissions
    }

    var body: some View {
        AppScreen {
            AdminImageOverview(images: store.images)

            if let error = store.errorMessage {
                AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            AppSectionHeader(
                title: "Фотографии на сервере",
                caption: "Общий просмотр и отдельные категории"
            )

            if store.isLoading && store.images.isEmpty {
                AppLoadingView(title: "Читаю каталог сервера")
            } else {
                VStack(spacing: 12) {
                    ForEach(AdminImageSection.allCases) { section in
                        NavigationLink {
                            catalogDestination(for: section)
                        } label: {
                            AdminImageSectionRow(
                                section: section,
                                images: store.images.filter { section.kinds.contains($0.kind) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Изображения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Обновить изображения")
            }
        }
        .refreshable { await store.load() }
        .task {
            if !store.hasLoaded { await store.load() }
        }
    }

    @ViewBuilder
    private func catalogDestination(for section: AdminImageSection) -> some View {
        switch section {
        case .all, .userAvatars, .vehicles, .officeEquipment, .backpackTerminals, .service:
            AdminImageCatalogScreen(
                section: section,
                store: store,
                permissions: permissions,
                token: token
            )
        }
    }
}

private struct AdminImageSectionRow: View {
    let section: AdminImageSection
    let images: [AdminServerImage]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 42, height: 42)
                .background(AppTheme.primaryTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.headline).foregroundStyle(AppTheme.ink)
                Text(section.caption).font(.caption).foregroundStyle(AppTheme.mutedTint)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(images.count.formatted()).font(.headline.weight(.bold)).foregroundStyle(AppTheme.ink)
                if images.contains(where: \.isMissing) {
                    Text("Нет фото: \(images.filter(\.isMissing).count)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryTint)
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(AppTheme.mutedTint)
        }
        .padding(16)
        .background(AppTheme.cardSurface.opacity(0.84), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

private struct AdminImageCatalogScreen: View {
    let section: AdminImageSection
    let store: AdminImagesStore
    let permissions: Set<AdminPermission>
    let token: String?

    @State private var searchText = ""
    @State private var sheet: AdminImageSheetDestination?
    @State private var deleteCandidate: AdminServerImage?

    private var images: [AdminServerImage] {
        let query = searchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLocale.russian)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return store.images.filter { image in
            section.kinds.contains(image.kind) && (query.isEmpty || image.searchableText.contains(query))
        }
    }

    private var creatableKind: AdminServerImageKind? {
        switch section {
        case .officeEquipment: .officeEquipment
        case .backpackTerminals: .backpackTerminal
        case .all, .userAvatars, .vehicles, .service: nil
        }
    }

    var body: some View {
        AppScreen {
            if let error = store.errorMessage {
                AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
            }
            if let notice = store.notice {
                AppNoticeBanner(text: notice, tint: AppTheme.primaryTint)
            }

            AppSectionHeader(title: section.title, caption: "Показано \(images.count)")

            if store.isLoading && store.images.isEmpty {
                AppLoadingView(title: "Читаю каталог сервера")
            } else if images.isEmpty {
                AppEmptyState(
                    title: "Изображений нет",
                    message: creatableKind == nil ? "В этом разделе пока нет файлов." : "Добавьте первую модель и её фотографию.",
                    systemName: section.systemImage
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(images) { image in
                        Button { sheet = .asset(image) } label: { AdminImageTile(image: image) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if canDelete(image) {
                                    Button(deleteTitle(for: image), systemImage: "trash", role: .destructive) {
                                        deleteCandidate = image
                                    }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(text: $searchText, prompt: "Модель, алиас, файл")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if section == .vehicles {
                    NavigationLink {
                        AdminVehicleImagesScreen(token: token, permissions: permissions)
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Очередь и добавление автомобилей")
                }
                if let creatableKind, permissions.contains(.createImages) {
                    Button { sheet = .addCatalogImage(creatableKind) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Добавить фотографию")
                }
                Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Обновить изображения")
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .asset(let image):
                AdminImageDetailSheet(image: image, store: store, permissions: permissions)
                    .presentationDetents([.large])
            case .addCatalogImage(let kind):
                AdminAddCatalogImageSheet(kind: kind, store: store)
                    .presentationDetents([.large])
            }
        }
        .confirmationDialog(
            deleteCandidate.map(deleteTitle(for:)) ?? "Удалить?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                guard let image = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await store.delete(image) }
            }
            Button("Отмена", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteCandidate?.isMissing == true
                 ? "Пустая карточка будет удалена из каталога."
                 : "Файл будет удалён с сервера, а привязка останется доступной для новой загрузки.")
        }
        .refreshable { await store.load() }
    }

    private func canDelete(_ image: AdminServerImage) -> Bool {
        image.capabilities.canDelete && permissions.contains(.deleteImages)
    }

    private func deleteTitle(for image: AdminServerImage) -> String {
        image.isMissing ? "Удалить карточку" : "Удалить изображение"
    }
}

private struct AdminImageOverview: View {
    let images: [AdminServerImage]

    var body: some View {
        HStack(spacing: 0) {
            metric("Всего", value: images.count, icon: "photo.stack", tint: AppTheme.primaryTint)
            Divider().frame(height: 46)
            metric("На сервере", value: images.filter { !$0.isMissing }.count, icon: "server.rack", tint: .green)
            Divider().frame(height: 46)
            metric("Нет файла", value: images.filter(\.isMissing).count, icon: "photo.badge.exclamationmark", tint: AppTheme.secondaryTint)
            Divider().frame(height: 46)
            metric("Без связей", value: images.filter { $0.kind == .orphan }.count, icon: "trash.slash", tint: AppTheme.dangerTint)
        }
        .padding(.vertical, 10)
        .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func metric(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(value.formatted()).font(.headline.weight(.bold)).foregroundStyle(AppTheme.ink)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.mutedTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct AdminImageTile: View {
    let image: AdminServerImage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(previewBackground)
                if let url = image.imageUrl, !image.isMissing {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let loaded):
                            loaded.resizable().scaledToFit().padding(8)
                        case .failure:
                            placeholder(systemImage: "exclamationmark.triangle")
                        case .empty:
                            ProgressView()
                        @unknown default:
                            placeholder(systemImage: image.kind.systemImage)
                        }
                    }
                } else {
                    placeholder(systemImage: image.kind.systemImage)
                }
            }
            .frame(height: 108)
            .overlay(alignment: .topTrailing) {
                if image.isMissing || image.kind == .orphan {
                    Image(systemName: image.isMissing ? "exclamationmark.circle.fill" : "link.badge.plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(image.kind == .orphan ? AppTheme.dangerTint : AppTheme.secondaryTint)
                        .padding(8)
                }
            }

            Text(image.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
            HStack(spacing: 5) {
                Image(systemName: image.kind.systemImage)
                Text(image.kind.title)
                Spacer(minLength: 0)
                if image.usageCount > 0 {
                    Text("×\(image.usageCount)")
                }
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.mutedTint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var previewBackground: Color {
        image.kind == .vehicleCatalog || image.kind == .system ? Color.black.opacity(0.82) : AppTheme.primaryTint.opacity(0.08)
    }

    private func placeholder(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(AppTheme.mutedTint)
    }
}

private struct AdminImageDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: AdminServerImage
    let store: AdminImagesStore
    let permissions: Set<AdminPermission>

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsDeleteConfirmation = false
    @State private var make: String
    @State private var model: String
    @State private var generation: String
    @State private var year: String
    @State private var bodyType: String
    @State private var colorName: String
    @State private var referenceName: String
    @State private var aliases: String

    init(image: AdminServerImage, store: AdminImagesStore, permissions: Set<AdminPermission>) {
        self.image = image
        self.store = store
        self.permissions = permissions
        _make = State(initialValue: image.metadata["make"] ?? "")
        _model = State(initialValue: image.metadata["model"] ?? "")
        _generation = State(initialValue: image.metadata["generation"] ?? "")
        _year = State(initialValue: image.metadata["year"] ?? "")
        _bodyType = State(initialValue: image.metadata["bodyType"] ?? "")
        _colorName = State(initialValue: image.metadata["colorName"] ?? "")
        _referenceName = State(initialValue: image.metadata["referenceName"] ?? image.title)
        _aliases = State(initialValue: image.aliases.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    imagePreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Назначение") {
                    Text(image.purpose)
                    LabeledContent("Тип", value: image.kind.title)
                    LabeledContent("Использований", value: image.usageCount.formatted())
                    if image.sharedReferenceCount > 1 {
                        LabeledContent("Общий файл", value: "\(image.sharedReferenceCount) привязки")
                    }
                    if let path = image.path {
                        LabeledContent("Путь") {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let size = image.sizeBytes {
                        LabeledContent("Размер", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let width = image.width, let height = image.height {
                        LabeledContent("Разрешение", value: "\(width) × \(height)")
                    }
                }

                if image.capabilities.canEditMetadata, permissions.contains(.editImages) {
                    metadataEditor
                }

                if image.kind == .officeEquipment {
                    equipmentPromptSection
                }

                Section("Связанные переменные") {
                    if image.bindings.isEmpty {
                        Text("Связей нет").foregroundStyle(.secondary)
                    } else {
                        ForEach(image.bindings) { binding in
                            LabeledContent {
                                Text(binding.value)
                                    .font(.caption.monospaced())
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            } label: {
                                Text(binding.name).font(.caption)
                            }
                        }
                    }
                }

                if canUpload || canDelete {
                    Section("Действия") {
                        if canUpload {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label(
                                    image.isMissing ? "Загрузить изображение" : "Заменить изображение",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            if store.uploadingImageID == image.id, let progress = store.uploadProgress {
                                ProgressView(value: progress) {
                                    Text("Загрузка \(Int(progress * 100))%")
                                }
                            }
                        }
                        if canDelete {
                            Button(deleteTitle, systemImage: "trash", role: .destructive) {
                                showsDeleteConfirmation = true
                            }
                        }
                    }
                }
            }
            .navigationTitle(image.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Закрыть")
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { selectedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    store.errorMessage = "Не удалось прочитать выбранный файл."
                    return
                }
                if (image.kind == .vehicleCatalog || image.kind == .officeEquipment || image.kind == .backpackTerminal),
                   !adminIsTransparentPNG(data) {
                    store.errorMessage = "Нужен настоящий PNG с прозрачным фоном."
                    return
                }
                if await store.upload(data, for: image) { dismiss() }
            }
        }
        .confirmationDialog(
            image.kind == .orphan ? "Удалить неиспользуемый файл?" : "\(deleteTitle)?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                Task {
                    if await store.delete(image) { dismiss() }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(image.kind == .orphan
                 ? "Файл не связан с БД или manifest и будет удалён с сервера."
                 : (image.isMissing
                    ? "Пустая карточка будет удалена из каталога."
                    : "Файл будет удалён, а привязка останется доступной для новой загрузки."))
        }
    }

    private var canUpload: Bool {
        image.capabilities.canUpload
            && permissions.contains(image.isMissing ? .createImages : .editImages)
    }

    private var canDelete: Bool {
        image.capabilities.canDelete && permissions.contains(.deleteImages)
    }

    private var deleteTitle: String {
        image.isMissing ? "Удалить карточку" : "Удалить изображение"
    }

    private var imagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(image.kind == .vehicleCatalog || image.kind == .system ? Color.black.opacity(0.86) : AppTheme.primaryTint.opacity(0.08))
            if let url = image.imageUrl, !image.isMissing {
                AsyncImage(url: url) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFit().padding(14)
                    } else if phase.error != nil {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                ContentUnavailableView("Файл не загружен", systemImage: image.kind.systemImage)
            }
        }
        .frame(height: 220)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var metadataEditor: some View {
        if image.kind == .vehicleCatalog {
            Section("Параметры автомобиля") {
                TextField("Марка", text: $make)
                TextField("Модель", text: $model)
                TextField("Поколение", text: $generation)
                TextField("Год", text: $year).keyboardType(.numberPad)
                TextField("Кузов", text: $bodyType)
                TextField("Цвет", text: $colorName)
                Button("Сохранить переменные") {
                    Task {
                        var body: [String: Any] = [
                            "make": optionalJSON(make),
                            "model": optionalJSON(model),
                            "generation": optionalJSON(generation),
                            "bodyType": optionalJSON(bodyType),
                            "colorName": optionalJSON(colorName)
                        ]
                        body["year"] = Int(year) ?? NSNull()
                        if await store.updateMetadata(image, body: body) { dismiss() }
                    }
                }
                .disabled(
                    make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        } else if image.kind == .officeEquipment || image.kind == .backpackTerminal {
            Section("Сопоставление с оборудованием") {
                TextField("Основное название", text: $referenceName, axis: .vertical)
                TextField("Алиасы, по одному в строке", text: $aliases, axis: .vertical)
                    .lineLimit(3 ... 8)
                Button("Сохранить переменные") {
                    Task {
                        let values = aliases
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if await store.updateMetadata(
                            image,
                            body: ["referenceName": referenceName, "aliases": values]
                        ) { dismiss() }
                    }
                }
                .disabled(referenceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func optionalJSON(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSNull() : trimmed
    }

    private var equipmentPromptSection: some View {
        Section("Системный промпт") {
            Text(EquipmentImageGenerationPrompt.text(for: referenceName))
                .font(.caption)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = EquipmentImageGenerationPrompt.text(for: referenceName)
                store.notice = "Промпт оборудования скопирован."
            } label: {
                Label("Скопировать промпт", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct AdminAddCatalogImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: AdminServerImageKind
    let store: AdminImagesStore
    @State private var referenceName = ""
    @State private var aliases = ""
    @State private var isSaving = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var photoError: String?
    @State private var simpleOneLogin = ""
    @State private var isLoadingEquipment = false
    @State private var equipment: [OfficeEquipmentItem] = []
    @State private var lookupError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Основное название модели", text: $referenceName, axis: .vertical)
                    TextField("Алиасы, по одному в строке", text: $aliases, axis: .vertical)
                        .lineLimit(3 ... 8)
                } header: {
                    Text(kind == .officeEquipment ? "Связь с личным оборудованием" : "Модель терминала")
                } footer: {
                    if kind == .officeEquipment {
                        Text("Фото сопоставляется по названию, вендору, модели и альтернативному наименованию из SimpleOne.")
                    } else {
                        Text("Алиасы используются для сопоставления названий терминала в рюкзаке.")
                    }
                }

                if kind == .officeEquipment {
                    Section {
                        TextField("Логин пользователя SimpleOne", text: $simpleOneLogin)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await loadEquipment() }
                        } label: {
                            if isLoadingEquipment {
                                HStack { ProgressView(); Text("Загружаю список") }
                            } else {
                                Label("Получить оборудование", systemImage: "person.text.rectangle")
                            }
                        }
                        .disabled(simpleOneLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingEquipment)

                        if let lookupError {
                            Text(lookupError).foregroundStyle(.red)
                        }

                        ForEach(equipment) { item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.displayName).foregroundStyle(AppTheme.ink)
                                    Text([item.vendor, item.model, item.serialNumber].filter { !$0.isEmpty }.joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedTint)
                                }
                            }
                        }
                    } header: {
                        Text("Взять название из SimpleOne")
                    } footer: {
                        Text("Используется текущая авторизация SimpleOne. Выберите устройство — название и алиасы заполнятся автоматически.")
                    }
                }

                Section {
                    if let selectedPhotoData, let preview = UIImage(data: selectedPhotoData) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
                            .background(AppTheme.primaryTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(
                            selectedPhotoData == nil ? "Выбрать прозрачный PNG" : "Заменить выбранное фото",
                            systemImage: "photo.badge.plus"
                        )
                    }
                    if let photoError {
                        Text(photoError).foregroundStyle(AppTheme.dangerTint)
                    }
                } header: {
                    Text("Фотография")
                } footer: {
                    Text("Фото загружается вместе с созданием записи. Нужен настоящий PNG с прозрачным фоном, до 20 МБ.")
                }

                if kind == .officeEquipment {
                    Section("Системный промпт") {
                        Text(EquipmentImageGenerationPrompt.text(for: referenceName))
                            .font(.caption)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = EquipmentImageGenerationPrompt.text(for: referenceName)
                            store.notice = "Промпт оборудования скопирован."
                        } label: {
                            Label("Скопировать промпт", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .navigationTitle(kind == .officeEquipment ? "Новое оборудование" : "Новый терминал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        Task { await create() }
                    }
                    .disabled(
                        referenceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || selectedPhotoData == nil
                            || isSaving
                    )
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    selectedPhotoData = nil
                    photoError = "Не удалось прочитать выбранный файл."
                    return
                }
                guard data.count <= 20 * 1024 * 1024 else {
                    selectedPhotoData = nil
                    photoError = "Изображение не должно превышать 20 МБ."
                    return
                }
                guard adminIsTransparentPNG(data) else {
                    selectedPhotoData = nil
                    photoError = "Нужен настоящий PNG с прозрачным фоном."
                    return
                }
                selectedPhotoData = data
                photoError = nil
            }
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        let values = aliases
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let selectedPhotoData else { return }
        if await store.createCatalogImage(
            kind: kind,
            referenceName: referenceName,
            aliases: values,
            imageData: selectedPhotoData
        ) {
            dismiss()
        }
    }

    private func loadEquipment() async {
        guard let authKey = SimpleOneSessionKeychain.readAuthKey() else {
            lookupError = "Сначала войдите в SimpleOne на экране «Заявки»."
            return
        }
        isLoadingEquipment = true
        lookupError = nil
        defer { isLoadingEquipment = false }
        do {
            equipment = try await SimpleOneRequestsService().fetchOfficeEquipment(
                login: simpleOneLogin,
                authKey: authKey
            )
            if equipment.isEmpty {
                lookupError = "У пользователя нет оборудования по фильтру владельца."
            }
        } catch {
            lookupError = appUserFacingErrorMessage(error)
        }
    }

    private func select(_ item: OfficeEquipmentItem) {
        referenceName = item.photoReferenceName
        aliases = item.photoCandidateNames
            .filter { $0.localizedCaseInsensitiveCompare(referenceName) != .orderedSame }
            .joined(separator: "\n")
        AppHaptics.trigger()
    }
}

struct AdminVehicleImageRequest: Identifiable, Hashable {
    var id: String
    var status: String
    var prompt: String
    var rejectionReason: String?
    var userEmail: String
    var vehicle: Vehicle
}

struct ManualVehicleImageDraft: Equatable {
    var make = ""
    var model = ""
    var generation = ""
    var year = ""
    var bodyType = ""
    var colorName = ""

    var canPrepare: Bool {
        !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (parsedYear != nil || year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var parsedYear: Int? {
        guard let value = Int(year.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1886 ... Calendar.current.component(.year, from: Date()) + 1).contains(value)
        else { return nil }
        return value
    }

    var payload: [String: Any] {
        [
            "make": make.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "generation": optional(generation),
            "year": parsedYear.map { $0 as Any } ?? NSNull(),
            "bodyType": optional(bodyType),
            "colorName": optional(colorName)
        ]
    }

    private func optional(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSNull() : trimmed
    }
}

struct PreparedManualVehicleImage: Equatable {
    var catalogKey: String
    var prompt: String
    var imageURL: URL?
    var appliedVehicleCount: Int
}

struct AdminVehicleImagesAPI {
    private let baseURL = AppConfig.configuredURL(AppConfig().lumaWorkAPIOrigin)
    private let client = HTTPClient()

    func fetch(token: String) async throws -> [AdminVehicleImageRequest] {
        let response = try await client.request(url("/api/v2/admin/vehicle-image-requests"), authToken: token)
        return (dictionaryValue(response.json)?["requests"] as? [Any] ?? []).compactMap { raw in
            guard let dictionary = dictionaryValue(raw),
                  let vehicleRaw = dictionary["vehicle"],
                  let vehicle = VehicleAPI.vehicle(vehicleRaw) else { return nil }
            return AdminVehicleImageRequest(
                id: stringValue(dictionary["id"]),
                status: stringValue(dictionary["status"]),
                prompt: stringValue(dictionary["prompt"]),
                rejectionReason: stringValue(dictionary["rejectionReason"]).nilIfBlank,
                userEmail: stringValue(dictionaryValue(dictionary["user"])?["email"]),
                vehicle: vehicle
            )
        }
    }

    func start(id: String, token: String) async throws {
        _ = try await client.request(url("/api/v2/admin/vehicle-image-requests/\(id)/start"), method: "POST", body: [:], authToken: token)
    }

    func reject(id: String, reason: String, token: String) async throws {
        _ = try await client.request(url("/api/v2/admin/vehicle-image-requests/\(id)/reject"), method: "POST", body: ["reason": reason], authToken: token)
    }

    func uploadChunk(
        id: String,
        uploadID: String,
        chunkIndex: Int,
        totalChunks: Int,
        data: Data,
        token: String
    ) async throws {
        _ = try await client.request(
            url("/api/v2/admin/vehicle-image-requests/\(id)/image-chunk"),
            method: "POST",
            body: [
                "uploadId": uploadID,
                "chunkIndex": chunkIndex,
                "totalChunks": totalChunks,
                "chunkBase64": data.base64EncodedString()
            ],
            authToken: token
        )
    }

    func prepareManual(_ draft: ManualVehicleImageDraft, token: String) async throws -> PreparedManualVehicleImage {
        let response = try await client.request(
            url("/api/v2/admin/vehicle-images/catalog/prepare"),
            method: "POST",
            body: draft.payload,
            authToken: token
        )
        let dictionary = dictionaryValue(response.json) ?? [:]
        let imageURL = stringValue(dictionary["imageUrl"]).nilIfBlank.flatMap(URL.init(string:))
        return PreparedManualVehicleImage(
            catalogKey: stringValue(dictionary["catalogKey"]),
            prompt: stringValue(dictionary["prompt"]),
            imageURL: imageURL,
            appliedVehicleCount: (dictionary["appliedVehicleCount"] as? NSNumber)?.intValue ?? 0
        )
    }

    func uploadManualChunk(
        catalogKey: String,
        uploadID: String,
        chunkIndex: Int,
        totalChunks: Int,
        data: Data,
        token: String
    ) async throws -> [String: Any] {
        let response = try await client.request(
            url("/api/v2/admin/vehicle-images/catalog/image-chunk"),
            method: "POST",
            body: [
                "catalogKey": catalogKey,
                "uploadId": uploadID,
                "chunkIndex": chunkIndex,
                "totalChunks": totalChunks,
                "chunkBase64": data.base64EncodedString()
            ],
            authToken: token
        )
        return dictionaryValue(response.json) ?? [:]
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor @Observable
final class AdminVehicleImagesStore {
    private let token: String?
    private let api = AdminVehicleImagesAPI()
    var requests: [AdminVehicleImageRequest] = []
    var isLoading = false
    var errorMessage: String?
    var notice: String?
    var uploadingRequestID: String?
    var uploadProgress: Double?
    var preparedManualImage: PreparedManualVehicleImage?
    var isPreparingManual = false
    var isUploadingManual = false
    var manualUploadProgress: Double?

    init(token: String?) { self.token = token }

    func load() async {
        guard let token else { errorMessage = "Требуется авторизация администратора."; return }
        isLoading = true
        defer { isLoading = false }
        do { requests = try await api.fetch(token: token) }
        catch { errorMessage = appUserFacingErrorMessage(error) }
    }

    func start(_ request: AdminVehicleImageRequest) async {
        await mutate { token in try await api.start(id: request.id, token: token) }
    }

    func reject(_ request: AdminVehicleImageRequest) async {
        await mutate { token in try await api.reject(id: request.id, reason: "Изображение не соответствует автомобилю или требованиям прозрачности.", token: token) }
    }

    func upload(_ data: Data, for request: AdminVehicleImageRequest) async {
        guard let token else { return }
        let chunkSize = 512 * 1024
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        let uploadID = UUID().uuidString.lowercased()

        isLoading = true
        errorMessage = nil
        uploadingRequestID = request.id
        uploadProgress = 0
        defer {
            isLoading = false
            uploadingRequestID = nil
            uploadProgress = nil
        }

        do {
            for index in 0 ..< totalChunks {
                let lowerBound = index * chunkSize
                let upperBound = min(lowerBound + chunkSize, data.count)
                try await api.uploadChunk(
                    id: request.id,
                    uploadID: uploadID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    data: data.subdata(in: lowerBound ..< upperBound),
                    token: token
                )
                uploadProgress = Double(index + 1) / Double(totalChunks)
            }
            notice = "Изображение загружено и применено к автомобилю."
            await load()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func prepareManual(_ draft: ManualVehicleImageDraft) async {
        guard let token else { return }
        isPreparingManual = true
        errorMessage = nil
        notice = nil
        defer { isPreparingManual = false }
        do {
            preparedManualImage = try await api.prepareManual(draft, token: token)
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func invalidateManualPreparation() {
        preparedManualImage = nil
        manualUploadProgress = nil
    }

    func uploadManual(_ data: Data) async {
        guard let token, let preparedManualImage else { return }
        let chunkSize = 512 * 1024
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        let uploadID = UUID().uuidString.lowercased()

        isUploadingManual = true
        errorMessage = nil
        notice = nil
        manualUploadProgress = 0
        defer { isUploadingManual = false }

        do {
            var finalResponse: [String: Any] = [:]
            for index in 0 ..< totalChunks {
                let lowerBound = index * chunkSize
                let upperBound = min(lowerBound + chunkSize, data.count)
                finalResponse = try await api.uploadManualChunk(
                    catalogKey: preparedManualImage.catalogKey,
                    uploadID: uploadID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    data: data.subdata(in: lowerBound ..< upperBound),
                    token: token
                )
                manualUploadProgress = Double(index + 1) / Double(totalChunks)
            }
            notice = "Изображение добавлено в каталог и применено к подходящим автомобилям."
            self.preparedManualImage?.imageURL = URL(string: stringValue(finalResponse["imageUrl"]))
            self.preparedManualImage?.appliedVehicleCount = (finalResponse["appliedVehicleCount"] as? NSNumber)?.intValue ?? 0
            await load()
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func mutate(_ action: (String) async throws -> Void) async {
        guard let token else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { try await action(token); notice = "Изменения сохранены."; await load() }
        catch { errorMessage = appUserFacingErrorMessage(error) }
    }
}

struct AdminVehicleImagesScreen: View {
    @State private var store: AdminVehicleImagesStore
    @State private var manualDraft = ManualVehicleImageDraft()
    @State private var manualPhoto: PhotosPickerItem?
    @State private var showsManualDetails = false
    @State private var showsManualPrompt = false
    private let permissions: Set<AdminPermission>

    init(token: String?, permissions: Set<AdminPermission>) {
        _store = State(initialValue: AdminVehicleImagesStore(token: token))
        self.permissions = permissions
    }

    var body: some View {
        AppScreen {
            if canCreateImages {
                AppSectionHeader(
                    title: "Добавить без очереди",
                    caption: "Создайте позицию каталога и загрузите PNG напрямую"
                )
                manualCatalogEditor
            }

            if let error = store.errorMessage { AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true) }
            if let notice = store.notice { AppNoticeBanner(text: notice, tint: AppTheme.primaryTint) }
            if !canManageWorkflow {
                AppNoticeBanner(
                    text: "Очередь доступна только для просмотра. Для действий нужно право добавлять или редактировать изображения.",
                    tint: AppTheme.secondaryTint,
                    style: .information
                )
            }

            AppSectionHeader(
                title: "Очередь",
                caption: activeRequests.isEmpty ? "Очередь пуста" : "Ожидают изображения: \(activeRequests.count)"
            )
            if store.isLoading {
                AppLoadingView(title: "Загружаю очередь изображений")
            }
            if activeRequests.isEmpty, !store.isLoading {
                AppEmptyState(title: "Очередь пуста", message: "Для всех автомобилей есть изображения.", systemName: "car.side")
            }
            ForEach(activeRequests) { request in
                AdminVehicleImageRequestCard(
                    request: request,
                    store: store,
                    canManageWorkflow: canManageWorkflow
                )
            }
        }
        .navigationTitle("Изображения автомобилей")
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .task { await store.load() }
        .refreshable { await store.load() }
        .onChange(of: manualDraft) { _, _ in
            store.invalidateManualPreparation()
        }
        .onChange(of: manualPhoto) { _, item in
            guard canCreateImages, let item else { return }
            Task {
                defer { manualPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    store.errorMessage = "Не удалось прочитать выбранный файл."
                    return
                }
                guard adminIsTransparentPNG(data) else {
                    store.errorMessage = "Выберите настоящий PNG с прозрачным фоном."
                    return
                }
                await store.uploadManual(data)
            }
        }
    }

    private var manualCatalogEditor: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Новая позиция каталога", systemImage: "car.side.badge.plus")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)

                Text("Марка и модель обязательны. Год и цвет уточняют промпт и соответствие автомобилям пользователей.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)

                manualField("Марка", text: $manualDraft.make, contentType: .organizationName)
                manualField("Модель", text: $manualDraft.model)

                HStack(spacing: 10) {
                    manualField("Год", text: $manualDraft.year, keyboard: .numberPad)
                    manualField("Цвет", text: $manualDraft.colorName)
                }

                DisclosureGroup("Дополнительные параметры", isExpanded: $showsManualDetails) {
                    VStack(spacing: 10) {
                        manualField("Поколение", text: $manualDraft.generation)
                        manualField("Тип кузова", text: $manualDraft.bodyType)
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

                Button {
                    AppHaptics.trigger()
                    Task { await store.prepareManual(manualDraft) }
                } label: {
                    if store.isPreparingManual {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Сформировать промпт", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manualDraft.canPrepare || store.isPreparingManual || store.isUploadingManual)

                if let prepared = store.preparedManualImage {
                    Divider()

                    HStack {
                        Label("Промпт готов", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                        Spacer()
                        Text("Совпадений: \(prepared.appliedVehicleCount)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }

                    DisclosureGroup("Показать промпт", isExpanded: $showsManualPrompt) {
                        Text(prepared.prompt)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                            .textSelection(.enabled)
                            .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                    Button {
                        UIPasteboard.general.string = prepared.prompt
                        store.notice = "Промпт скопирован."
                    } label: {
                        Label("Скопировать промпт", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if prepared.imageURL != nil {
                        Text("Изображение, которое сейчас хранится в каталоге")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                        VehicleImagePreview(imageURL: prepared.imageURL)
                    }

                    PhotosPicker(selection: $manualPhoto, matching: .images) {
                        Label(
                            prepared.imageURL == nil ? "Загрузить PNG на сервер" : "Заменить PNG на сервере",
                            systemImage: "square.and.arrow.up"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isUploadingManual)

                    if store.isUploadingManual, let progress = store.manualUploadProgress {
                        ProgressView(value: progress) {
                            Text("Загрузка \(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                }
            }
        }
    }

    private func manualField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .textContentType(contentType)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(AppTheme.cardSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var activeRequests: [AdminVehicleImageRequest] {
        store.requests.filter { $0.status != "APPROVED" }
    }

    private var canCreateImages: Bool {
        permissions.contains(.createImages)
    }

    private var canManageWorkflow: Bool {
        permissions.contains(.createImages) || permissions.contains(.editImages)
    }
}

private struct AdminVehicleImageRequestCard: View {
    let request: AdminVehicleImageRequest
    @Bindable var store: AdminVehicleImagesStore
    let canManageWorkflow: Bool
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPrompt = false

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.vehicle.displayName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                        Text(request.userEmail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                        if let plate = request.vehicle.licensePlate {
                            Text(plate)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                    }
                    Spacer()
                    AppBadge(text: statusTitle(request.status), tint: statusTint(request.status))
                }

                vehicleParameters

                Text("Текущее изображение")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedTint)
                VehicleImagePreview(imageURL: request.vehicle.imageStatus == "ready" ? request.vehicle.imageURL : nil)

                workflowTitle("1", "Скопируйте промпт")
                DisclosureGroup(isExpanded: $showsPrompt) {
                    Text(request.prompt)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                        .textSelection(.enabled)
                        .padding(.top, 10)
                } label: {
                    Label("Промпт для генерации", systemImage: "text.quote")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                }

                Button {
                    UIPasteboard.general.string = request.prompt
                    store.notice = "Промпт для \(request.vehicle.displayName) скопирован."
                    if canManageWorkflow && (request.status == "PENDING" || request.status == "REJECTED") {
                        Task { await store.start(request) }
                    }
                } label: {
                    Label("Скопировать промпт", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                workflowTitle("2", "Сгенерируйте изображение")
                Text("Приложите референс с автомобилем под чехлом. Результат должен быть PNG с настоящим прозрачным фоном.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedTint)

                if canManageWorkflow {
                    workflowTitle("3", "Загрузите готовый PNG")
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Выбрать и загрузить PNG", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)
                }

                if store.uploadingRequestID == request.id, let progress = store.uploadProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text("Загрузка: \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedTint)
                    }
                }

                if canManageWorkflow, request.status != "APPROVED" {
                    Button("Отклонить изображение", role: .destructive) {
                        Task { await store.reject(request) }
                    }
                    .font(.footnote.weight(.semibold))
                }

                if let reason = request.rejectionReason {
                    AppNoticeBanner(text: reason, tint: AppTheme.dangerTint, isCritical: true)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard canManageWorkflow, let item else { return }
            Task {
                defer { selectedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    store.errorMessage = "Не удалось прочитать выбранный файл."
                    return
                }
                guard adminIsTransparentPNG(data) else {
                    store.errorMessage = "Выберите настоящий PNG с прозрачным фоном."
                    return
                }
                await store.upload(data, for: request)
            }
        }
    }

    private func workflowTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.primaryTint)
                .frame(width: 22, height: 22)
                .background(AppTheme.primaryTint.opacity(0.14), in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
        }
    }

    private var vehicleParameters: some View {
        VStack(spacing: 7) {
            parameter("Марка", request.vehicle.make)
            parameter("Модель", request.vehicle.model)
            parameter("Поколение", request.vehicle.generation)
            parameter("Год", request.vehicle.year.map(String.init))
            parameter("Кузов", request.vehicle.bodyType)
            parameter("Цвет", request.vehicle.colorName)
        }
        .padding(12)
        .background(AppTheme.cardSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func parameter(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(AppTheme.mutedTint)
            Spacer()
            Text(value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "—")
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func statusTitle(_ value: String) -> String {
        ["PENDING": "Ожидает", "IN_PROGRESS": "В работе", "APPROVED": "Готово", "REJECTED": "Отклонено"][value] ?? value
    }

    private func statusTint(_ value: String) -> Color {
        switch value {
        case "APPROVED": AppTheme.primaryTint
        case "REJECTED": AppTheme.dangerTint
        default: AppTheme.secondaryTint
        }
    }
}

private struct VehicleImagePreview: View {
    let imageURL: URL?
    var body: some View {
        HStack(spacing: 0) {
            preview(background: .white)
            preview(background: .black)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func preview(background: Color) -> some View {
        ZStack {
            background
            CachedVehicleImage(url: imageURL)
        }.frame(maxWidth: .infinity)
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private func adminIsTransparentPNG(_ data: Data) -> Bool {
    guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return false }
    return properties[kCGImagePropertyHasAlpha] as? Bool == true
}
