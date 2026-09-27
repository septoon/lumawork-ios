import Foundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

extension SalaryEntry {
    static let netPaymentStartDate = "2026-05-13"

    var accrualMonthKey: String {
        if let periodMonth, periodMonth.count == 7 {
            return periodMonth
        }
        return String(date.prefix(7))
    }

    var usesNetPaymentAmount: Bool {
        amount != nil || date >= Self.netPaymentStartDate
    }

    var netPaymentAmount: Double {
        amount ?? baseSalary + weekendPay
    }

    var paymentKind: SalaryPaymentKind {
        kind ?? inferredPaymentKind
    }

    var isLegacySalaryEntry: Bool {
        !usesNetPaymentAmount
    }

    private var inferredPaymentKind: SalaryPaymentKind {
        guard usesNetPaymentAmount else {
            return .salary
        }
        let dayText = String(date.suffix(2))
        if let day = Int(dayText), day <= 10 {
            return .salary
        }
        return .advance
    }

    static func previousMonthKey(from monthKey: String) -> String? {
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1 ... 12).contains(month) else {
            return nil
        }
        if month == 1 {
            return "\(year - 1)-12"
        }
        return String(format: "%04d-%02d", year, month - 1)
    }
}

enum SalaryCalculations {
    static func payout(for entry: SalaryEntry) -> Double {
        if entry.usesNetPaymentAmount {
            return entry.netPaymentAmount
        }
        let tax = floor((entry.baseSalary + entry.weekendPay) * taxRate)
        return entry.baseSalary + entry.weekendPay - tax
    }

    static let taxRate = 0.13
}

struct SalarySummaryData: Equatable {
    let title: String
    let period: String
    let amount: Double
}

struct SalaryMonthSectionData: Identifiable, Equatable {
    let month: String
    let entryCount: Int
    let total: Double
    let entries: [SalaryEntry]

    var id: String {
        month
    }
}

struct SalaryProjection: Equatable {
    let years: [String]
    let monthsDescending: [SalaryMonthSectionData]
    let monthsByYear: [String: [SalaryMonthSectionData]]
    let latestSummary: SalarySummaryData?
    let allTimeSummary: SalarySummaryData?

    init(months: [SalaryMonth] = []) {
        let monthsAscending = Self.regroup(months: months).sorted { $0.month < $1.month }
        let monthSectionsAscending = monthsAscending.map { month in
            let entriesDescending = month.entries.sorted { $0.date > $1.date }
            return SalaryMonthSectionData(
                month: month.month,
                entryCount: month.entries.count,
                total: entriesDescending.reduce(0) { $0 + SalaryCalculations.payout(for: $1) },
                entries: entriesDescending
            )
        }

        let monthsDescending = Array(monthSectionsAscending.reversed())
        self.monthsDescending = monthsDescending
        years = Array(Set(monthSectionsAscending.map { String($0.month.prefix(4)) }))
            .sorted(by: >)
        monthsByYear = Dictionary(grouping: monthsDescending, by: { String($0.month.prefix(4)) })

        if let latestMonth = monthsAscending.last {
            let sortedEntries = latestMonth.entries.sorted { $0.date < $1.date }
            if let first = sortedEntries.first, let last = sortedEntries.last {
                latestSummary = SalarySummaryData(
                    title: AppFormatting.monthLabel(latestMonth.month),
                    period: "\(AppFormatting.shortDate(first.date)) - \(AppFormatting.shortDate(last.date))",
                    amount: sortedEntries.reduce(0) { $0 + SalaryCalculations.payout(for: $1) }
                )
            } else {
                latestSummary = nil
            }
        } else {
            latestSummary = nil
        }

        let allEntries = monthsAscending
            .flatMap(\.entries)
            .sorted { $0.date < $1.date }

        if let first = allEntries.first, let last = allEntries.last {
            allTimeSummary = SalarySummaryData(
                title: "\(monthsAscending.count) мес.",
                period: "\(AppFormatting.shortDate(first.date)) - \(AppFormatting.shortDate(last.date))",
                amount: allEntries.reduce(0) { $0 + SalaryCalculations.payout(for: $1) }
            )
        } else {
            allTimeSummary = nil
        }
    }

    func months(for selectedYear: String?) -> [SalaryMonthSectionData] {
        guard let selectedYear else {
            return monthsDescending
        }
        return monthsByYear[selectedYear] ?? []
    }

    static func regroup(months: [SalaryMonth]) -> [SalaryMonth] {
        let groupedEntries = Dictionary(grouping: months.flatMap(\.entries), by: \.accrualMonthKey)
        return groupedEntries
            .map { month, entries in
                SalaryMonth(month: month, entries: entries.sorted { $0.date < $1.date })
            }
            .sorted { $0.month < $1.month }
    }
}

struct SalaryDocument: Codable, Identifiable, Hashable {
    let id: String
    let month: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let createdAt: String
    let updatedAt: String
}

struct SalaryDocumentUpload {
    let data: Data
    let fileName: String
    let mimeType: String

    init(sourceURL: URL) throws {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 20 * 1024 * 1024 {
            throw AppServiceError.message("Расчётный листок не должен превышать 20 МБ.")
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        switch fileExtension {
        case "pdf":
            mimeType = "application/pdf"
        case "html", "htm":
            mimeType = "text/html"
        default:
            throw AppServiceError.message("Поддерживаются только PDF и HTML.")
        }

        data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw AppServiceError.message("Выбранный расчётный листок пуст.")
        }
        guard data.count <= 20 * 1024 * 1024 else {
            throw AppServiceError.message("Расчётный листок не должен превышать 20 МБ.")
        }
        fileName = sourceURL.lastPathComponent
    }
}

struct LegacySalarySlipStore {
    func documents() -> [(month: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let fileExtension = url.pathExtension.lowercased()
            let month = url.deletingPathExtension().lastPathComponent
            guard supportedExtensions.contains(fileExtension), Self.isValidMonth(month) else { return nil }
            return (month, url)
        }
    }

    func fileURL(for month: String) -> URL? {
        supportedExtensions
            .map { directoryURL.appendingPathComponent("\(month).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func deleteDocument(for month: String) throws {
        try removeExistingDocument(for: month)
    }

    private func removeExistingDocument(for month: String) throws {
        for url in supportedExtensions.map({ directoryURL.appendingPathComponent("\(month).\($0)") }) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private let supportedExtensions = ["pdf", "html", "htm"]

    private var directoryURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("SalarySlips", isDirectory: true)
    }

    private static func isValidMonth(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              let month = Int(parts[1]) else {
            return false
        }
        return (1 ... 12).contains(month)
    }
}

struct SalaryDocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL

    @State private var isExporterPresented = false
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            SalaryDocumentPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Расчетный листок")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ModalCloseButton {
                            dismiss()
                        }
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            isExporterPresented = true
                        } label: {
                            Label("Сохранить", systemImage: "square.and.arrow.down")
                        }
                    }
                }
                .background {
                    if let exportErrorMessage {
                        AppNoticeBanner(text: exportErrorMessage, tint: AppTheme.dangerTint, isCritical: true)
                    }
                }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: SalaryExportDocument(url: url),
            contentType: SalarySlipDocument.contentType(for: url),
            defaultFilename: url.lastPathComponent
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = appUserFacingErrorMessage(
                    error,
                    fallback: "Не удалось сохранить документ."
                )
            } else {
                exportErrorMessage = nil
            }
        }
        .task(id: exportErrorMessage) {
            await appDismissTransientMessage(exportErrorMessage) { value in
                if exportErrorMessage == value {
                    exportErrorMessage = nil
                }
            }
        }
    }
}

struct SalaryDocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct SalaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        SalarySlipDocument.allowedContentTypes
    }

    let data: Data

    init(url: URL) {
        data = (try? Data(contentsOf: url)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum SalarySlipDocument {
    static let allowedContentTypes: [UTType] = [.pdf, .html]

    static func contentType(for url: URL) -> UTType {
        url.pathExtension.lowercased() == "pdf" ? .pdf : .html
    }
}
