import Foundation
import SwiftUI
import UIKit

struct ActiveSimpleOneRequestDetailScreen: View {
    @Environment(\.openURL) private var openURL

    let record: SimpleOneRequestRecord
    var simpleOneAuthKey: String?
    var lumaWorkAuthToken: String?
    var personalComment: ClientPersonalComment?
    var onEditPersonalComment: ((ClientPersonalComment) -> Void)?
    var onOpenWarehouseRequests: ((String) -> Void)?

    @State private var currentRecord: SimpleOneRequestRecord
    @State private var data: ActiveSimpleOneRequestData
    @State private var expandedSections: Set<ActiveSimpleOneSection> = [.task, .closureCode, .resolution]
    @State private var issueEquipmentError: String?
    @State private var chatQuestionsNotice: String?
    @State private var browserDestination: SimpleOneBrowserDestination?
    @State private var companyLookupSelection: CompanyLookupSelection?
    @State private var hidesBottomActions = false

    init(
        record: SimpleOneRequestRecord,
        simpleOneAuthKey: String? = nil,
        lumaWorkAuthToken: String? = nil,
        personalComment: ClientPersonalComment? = nil,
        onEditPersonalComment: ((ClientPersonalComment) -> Void)? = nil,
        onOpenWarehouseRequests: ((String) -> Void)? = nil
    ) {
        self.record = record
        self.simpleOneAuthKey = simpleOneAuthKey
        self.lumaWorkAuthToken = lumaWorkAuthToken
        self.personalComment = personalComment
        self.onEditPersonalComment = onEditPersonalComment
        self.onOpenWarehouseRequests = onOpenWarehouseRequests
        _currentRecord = State(initialValue: record)
        _data = State(initialValue: ActiveSimpleOneRequestData(record: record))
    }

    private var shouldShowIssueEquipmentAction: Bool {
        currentRecord.source == .active && simpleOneRecordURL != nil
    }

    private var simpleOneRecordURL: URL? {
        let sysID = currentRecord.sysID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sysID.isEmpty else { return nil }
        return AppConfig.configuredURL(AppConfig().simpleOneWebOrigin)
            .appendingPathComponent("record")
            .appendingPathComponent("itsm_request")
            .appendingPathComponent(sysID)
    }

    var body: some View {
        ZStack {
            ActiveRequestStyle.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    if let issueEquipmentError {
                        AppNoticeBanner(text: issueEquipmentError, tint: AppTheme.dangerTint, isCritical: true)
                    }

                    if let personalComment {
                        ClientPersonalCommentBlock(comment: personalComment) {
                            onEditPersonalComment?(personalComment)
                        }
                    }

                    ActiveRequestDisclosureCard(
                        title: ActiveSimpleOneSection.task.title,
                        isExpanded: binding(for: .task)
                    ) {
                        fieldStack(data.taskFields)
                    }

                    ForEach(data.visibleSections) { section in
                        ActiveRequestDisclosureCard(
                            title: section.title,
                            isExpanded: binding(for: section)
                        ) {
                            let fields = data.fields(for: section)
                            if fields.isEmpty {
                                ActiveRequestValueBlock(title: nil, value: "Нет данных")
                            } else {
                                fieldStack(fields)
                            }
                        }
                    }

                    if let chatQuestionsNotice {
                        AppNoticeBanner(
                            text: chatQuestionsNotice,
                            tint: AppTheme.secondaryTint,
                            style: .information
                        )
                    }

                    if data.shouldShowChatQuestions {
                        ActiveRequestChatQuestionsBlock(
                            kaAndPinAction: {
                                openKaAndPinQuestions()
                            },
                            ofdActivationAction: {
                                openOFDAActivationQuestions()
                            },
                            autoregAction: {
                                openAutoregQuestions()
                            }
                        )
                    }

                    ActiveRequestManagerQuestionBlock {
                        copyManagerQuestion()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            .appObserveVerticalScroll { direction in
                updateBottomActionVisibility(for: direction)
            }

        }
        .overlay(alignment: .bottom) {
            if shouldShowIssueEquipmentAction {
                issueEquipmentActionBar
                    .appBottomFloatingVisibility(isHidden: hidesBottomActions)
            }
        }
        .sheet(item: $browserDestination) { destination in
            SimpleOneEmbeddedBrowser(destination: destination)
        }
        .sheet(item: $companyLookupSelection) { selection in
            CompanyLookupSheet(selection: selection, authToken: lumaWorkAuthToken)
        }
        .navigationTitle("Детали")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .appSidebarBackButton()
        .onChange(of: record) { _, newRecord in
            currentRecord = newRecord
            data = ActiveSimpleOneRequestData(record: newRecord)
        }
    }

    private var issueEquipmentActionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ActiveRequestStyle.cardStroke)
                .frame(height: 1)

            Button {
                issueEquipment()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "safari.fill")
                        .font(.body.weight(.semibold))

                    Text("Выдача оборудования")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.primaryTint)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 0)
            .padding(.bottom, 8)
            .offset(y: 14)
            .background(.ultraThinMaterial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 8) {
                AppSelectableText(
                    text: data.requestNumber,
                    textStyle: .title3,
                    weight: .bold,
                    pointSize: 20,
                    design: .rounded,
                    color: ActiveRequestStyle.primaryText
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    AppHaptics.trigger()
                    UIPasteboard.general.string = data.requestNumber
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ActiveRequestStyle.mutedText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Скопировать номер заявки")
            }

            if let sla = data.sla {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        AppSelectableText(
                            text: sla.remainingText,
                            textStyle: .caption1,
                            weight: .bold,
                            color: sla.isOverdue ? AppTheme.dangerTint : ActiveRequestStyle.primaryText
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(ActiveRequestStyle.mutedText.opacity(0.18))
                                Capsule()
                                    .fill(sla.isOverdue ? AppTheme.dangerTint : ActiveRequestStyle.mutedText.opacity(0.95))
                                    .frame(width: max(8, proxy.size.width * CGFloat(sla.progress)))
                            }
                        }
                        .frame(height: 4)

                        Text("SLA")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ActiveRequestStyle.mutedText)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ActiveRequestHeaderMetric(icon: "alarm", title: data.deadlineText)
                ActiveRequestHeaderMetric(icon: "arrow.triangle.2.circlepath", title: data.requestTypeText)
                ActiveRequestHeaderMetric(
                    prefix: "TID",
                    title: data.terminalID,
                    isLinkLike: !warehouseTerminalID.isEmpty,
                    action: warehouseTerminalID.isEmpty ? nil : {
                        AppClipboard.copyTerminalID(warehouseTerminalID)
                    },
                    longPressAction: onOpenWarehouseRequests == nil || warehouseTerminalID.isEmpty ? nil : {
                        onOpenWarehouseRequests?(warehouseTerminalID)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var warehouseTerminalID: String {
        firstNonEmpty([
            currentRecord.terminalID,
            value(
                for: ["ID терминал", "ID терминала"],
                in: warehouseInformationFields(currentRecord)
            )
        ])
    }

    private func fieldStack(_ fields: [ActiveSimpleOneField]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(fields) { field in
                let opensYandexMaps = isAddressField(field)
                let opensCompanyLookup = isMerchantTINField(field)
                ActiveRequestValueBlock(
                    title: field.title,
                    value: field.value,
                    isLinkLike: field.isLinkLike || opensYandexMaps,
                    action: opensYandexMaps
                        ? { openYandexMaps(for: field.value) }
                        : opensCompanyLookup ? { openCompanyLookup(for: field.value) } : nil,
                    longPressAction: opensCompanyLookup ? {
                        AppClipboard.copy(field.value, message: "ИНН скопирован")
                    } : nil,
                    accessibilityHint: opensCompanyLookup
                        ? "Коснитесь, чтобы открыть данные организации. Удерживайте, чтобы скопировать ИНН."
                        : ""
                )
            }
        }
    }

    private func updateBottomActionVisibility(for direction: AppVerticalScrollDirection) {
        let shouldHide = direction == .down
        guard hidesBottomActions != shouldHide else { return }
        hidesBottomActions = shouldHide
    }

    private func isAddressField(_ field: ActiveSimpleOneField) -> Bool {
        field.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU")) == "адрес:"
    }

    private func isMerchantTINField(_ field: ActiveSimpleOneField) -> Bool {
        field.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU")) == "инн тсп:"
    }

    private func openCompanyLookup(for inn: String) {
        guard let selection = CompanyLookupSelection(inn: inn) else {
            AppBannerCenter.shared.show("Некорректный ИНН", style: .error)
            return
        }
        AppHaptics.trigger()
        companyLookupSelection = selection
    }

    private func binding(for section: ActiveSimpleOneSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedSections.insert(section)
                    } else {
                        expandedSections.remove(section)
                    }
                }
            }
        )
    }

    private func issueEquipment() {
        AppHaptics.trigger()
        issueEquipmentError = nil
        guard let url = simpleOneRecordURL else {
            issueEquipmentError = "Не удалось открыть заявку SimpleOne: нет sys_id."
            return
        }
        browserDestination = SimpleOneBrowserDestination(url: url, authKey: simpleOneAuthKey)
    }

    private func openKaAndPinQuestions() {
        openDionChatQuestion(message: data.kaAndPinMessage)
    }

    private func openOFDAActivationQuestions() {
        openDionChatQuestion(message: data.ofdActivationMessage)
    }

    private func openAutoregQuestions() {
        AppHaptics.trigger()
        chatQuestionsNotice = nil
        AppClipboard.copy(data.autoregMessage)
        chatQuestionsNotice = "Текст скопирован. После перехода в Telegram нажмите «Вставить» в поле сообщения."

        if let appURL = ActiveRequestChatQuestions.telegramAppURL,
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = ActiveRequestChatQuestions.telegramWebURL {
            openURL(webURL)
        } else {
            chatQuestionsNotice = "Ссылка на чат не настроена."
        }
    }

    private func copyManagerQuestion() {
        AppHaptics.trigger()
        AppClipboard.copy(data.managerQuestionMessage)
        chatQuestionsNotice = "Текст скопирован. Вставьте его в нужный чат менеджера."
    }

    private func openChatQuestion(message: String, destination: URL) {
        AppHaptics.trigger()
        chatQuestionsNotice = nil
        AppClipboard.copy(message)
        chatQuestionsNotice = "Текст скопирован. После перехода в чат нажмите «Вставить» в поле сообщения."
        openURL(destination)
    }

    private func openDionChatQuestion(message: String) {
        guard let destination = ActiveRequestChatQuestions.dionURL else {
            chatQuestionsNotice = "Чат Dion не настроен."
            return
        }
        openChatQuestion(message: message, destination: destination)
    }

    private func openYandexMaps(for address: String) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "yandex.ru"
        components.path = "/maps/"
        components.queryItems = [
            URLQueryItem(name: "text", value: trimmedAddress),
            URLQueryItem(name: "z", value: "16")
        ]

        guard let url = components.url else { return }
        AppHaptics.trigger()
        browserDestination = SimpleOneBrowserDestination(url: url, authKey: nil, title: "Яндекс Карты")
    }
}
