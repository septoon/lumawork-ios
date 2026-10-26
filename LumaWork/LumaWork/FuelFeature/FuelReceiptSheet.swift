import SwiftUI

struct FuelReceiptMonth: Identifiable {
    let id: String
}

struct FuelReceiptMonthButton: View {
    let store: FuelReceiptStore
    let month: String
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.trigger()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(FuelUI.accent)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("Чеки").fontWeight(.semibold)
                        Spacer(minLength: 8)
                        receiptCounts
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Чеки").fontWeight(.semibold)
                        receiptCounts
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FuelUI.mutedStrong)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(FuelUI.chipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(FuelReceiptButtonStyle())
        .accessibilityLabel("Чеки за \(AppFormatting.monthLabel(month))")
        .accessibilityValue("Фискальных: \(store.receipts(month: month, kind: .fiscal).count), банковских: \(store.receipts(month: month, kind: .bank).count)")
    }

    private var receiptCounts: some View {
        Text("\(store.receipts(month: month, kind: .fiscal).count) фиск. · \(store.receipts(month: month, kind: .bank).count) банк.")
            .foregroundStyle(FuelUI.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FuelReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: FuelReceiptStore
    let month: String
    @State private var selection: AttachmentSelection?
    @State private var isPickerPresented = false
    @State private var preview: ReceiptPreview?
    @State private var receiptToDelete: FuelReceipt?
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.errorMessage {
                    Section {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(FuelUI.danger)
                        Button("Повторить загрузку", systemImage: "arrow.clockwise") {
                            run { await store.load() }
                        }
                        .disabled(store.isBusy)
                    }
                } else if store.isShowingCachedData {
                    Section {
                        Label("Сохранённые чеки доступны без сети", systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let progress = store.uploadProgress {
                    Section {
                        ProgressView(value: progress) {
                            HStack {
                                Text("Загружаем чек")
                                Spacer()
                                Text(progress, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                        }
                        .tint(FuelUI.accent)
                    }
                } else if store.busyID != nil {
                    Section { ProgressView("Обрабатываем чек…") }
                } else if store.isLoading {
                    Section { ProgressView("Обновляем чеки…") }
                }

                ForEach(FuelReceiptKind.allCases) { kind in
                    Section {
                        let receipts = store.receipts(month: month, kind: kind)
                        if receipts.isEmpty {
                            Text("Пока нет чеков")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(receipts) { receipt in
                            receiptRow(receipt)
                        }
                        Button {
                            select(kind: kind)
                        } label: {
                            Label("Прикрепить чек", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 30)
                        }
                        .disabled(store.isBusy || store.authorizationFailed)
                        .accessibilityLabel("Прикрепить \(kind.attachmentTitle.lowercased())")
                    } header: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("PDF, JPEG, PNG, HEIC/HEIF · до 20 МБ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle("Чеки · \(AppFormatting.monthLabel(month))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
            .refreshable { await store.load() }
            .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: FuelReceiptUpload.allowedContentTypes) { result in
                guard let selection else { return }
                self.selection = nil
                switch result {
                case .success(let url):
                    run {
                        await store.upload(from: url, month: month, kind: selection.kind, replacing: selection.replacing)
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        store.errorMessage = appUserFacingErrorMessage(error)
                    }
                }
            }
            .sheet(item: $preview) { item in
                NavigationStack {
                    SalaryDocumentPreview(url: item.url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Чек")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                ModalCloseButton { preview = nil }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                ShareLink(item: item.url) {
                                    Label("Поделиться", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                }
            }
            .confirmationDialog("Удалить чек?", isPresented: .init(
                get: { receiptToDelete != nil },
                set: { if !$0 { receiptToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let receiptToDelete {
                        self.receiptToDelete = nil
                        run { await store.delete(receiptToDelete) }
                    }
                }
                Button("Отмена", role: .cancel) { receiptToDelete = nil }
            } message: {
                Text(receiptToDelete?.fileName ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await store.load() }
        .onDisappear { actionTask?.cancel() }
    }

    private func receiptRow(_ receipt: FuelReceipt) -> some View {
        HStack(spacing: 12) {
            Button {
                run {
                    if let url = await store.fileURL(for: receipt), !Task.isCancelled {
                        preview = ReceiptPreview(url: url)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: receipt.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                        .font(.title3)
                        .foregroundStyle(FuelUI.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.fileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(receipt.sizeBytes), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открыть чек")
            Menu {
                Button("Заменить", systemImage: "arrow.triangle.2.circlepath") {
                    select(kind: receipt.kind, replacing: receipt)
                }
                Button("Удалить", systemImage: "trash", role: .destructive) {
                    receiptToDelete = receipt
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Действия с чеком \(receipt.fileName)")
        }
        .disabled(store.isBusy || store.authorizationFailed)
    }

    private func select(kind: FuelReceiptKind, replacing: FuelReceipt? = nil) {
        AppHaptics.trigger()
        selection = AttachmentSelection(kind: kind, replacing: replacing)
        isPickerPresented = true
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        actionTask = Task { await operation() }
    }

    private struct AttachmentSelection {
        let kind: FuelReceiptKind
        let replacing: FuelReceipt?
    }

    private struct ReceiptPreview: Identifiable {
        let id = UUID()
        let url: URL
    }
}

private struct FuelReceiptButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
