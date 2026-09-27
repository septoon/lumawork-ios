import Foundation
import PDFKit
import UniformTypeIdentifiers
import UIKit
import Vision

nonisolated struct AssistantPreparedDocumentPayload: Sendable {
    let fileName: String
    let mimeType: String
    let text: String
    let extraction: String
    let sourceBytes: Int
    let wasTruncated: Bool
    let pageCount: Int?
    let sheetNames: [String]
    let rawData: Data?
}

nonisolated struct AssistantPreparedDocument: Sendable {
    let payload: AssistantPreparedDocumentPayload
    let fallbackImage: AssistantPreparedImagePayload?
}

nonisolated enum AssistantDocumentPreparationError: LocalizedError {
    case unsupportedFormat
    case fileTooLarge
    case unreadableDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Этот формат документа пока не поддерживается."
        case .fileTooLarge:
            "Документ слишком большой. Максимальный размер — 12 МБ."
        case .unreadableDocument:
            "Не удалось прочитать документ."
        case .emptyDocument:
            "В документе не найден текст для анализа."
        }
    }
}

nonisolated enum AssistantDocumentPreparer {
    static let supportedContentTypes: [UTType] = [
        .pdf,
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        .rtf,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "xlsx") ?? .data,
        UTType(filenameExtension: "doc") ?? .data,
        UTType(filenameExtension: "xls") ?? .data
    ]

    private static let maximumFileBytes = 12 * 1_024 * 1_024
    private static let maximumLegacyFileBytes = 5 * 1_024 * 1_024
    private static let maximumTextCharacters = 12_000
    private static let maximumArchiveEntryBytes = 8 * 1_024 * 1_024
    private static let maximumPDFPages = 30
    private static let maximumOCRPages = 8
    private static let maximumWorksheets = 6

    static func prepare(data: Data, fileName: String) async throws -> AssistantPreparedDocument {
        let extracted = try await Task.detached(priority: .userInitiated) {
            try prepareSynchronously(data: data, fileName: fileName)
        }.value
        let fallbackImage: AssistantPreparedImagePayload? = if let imageData = extracted.fallbackImageData {
            try? await AssistantImagePreparer.prepare(data: imageData)
        } else {
            nil
        }
        return AssistantPreparedDocument(payload: extracted.payload, fallbackImage: fallbackImage)
    }

    private static func prepareSynchronously(data: Data, fileName: String) throws -> ExtractionResult {
        guard !data.isEmpty else { throw AssistantDocumentPreparationError.unreadableDocument }
        guard data.count <= maximumFileBytes else { throw AssistantDocumentPreparationError.fileTooLarge }

        let safeName = sanitizedFileName(fileName)
        switch URL(fileURLWithPath: safeName).pathExtension.lowercased() {
        case "pdf":
            return try preparePDF(data: data, fileName: safeName)
        case "docx":
            return try prepareDOCX(data: data, fileName: safeName)
        case "xlsx":
            return try prepareXLSX(data: data, fileName: safeName)
        case "doc", "xls":
            guard data.count <= maximumLegacyFileBytes else {
                throw AssistantDocumentPreparationError.fileTooLarge
            }
            let extensionName = URL(fileURLWithPath: safeName).pathExtension.lowercased()
            return ExtractionResult(
                payload: AssistantPreparedDocumentPayload(
                    fileName: safeName,
                    mimeType: extensionName == "doc" ? "application/msword" : "application/vnd.ms-excel",
                    text: "",
                    extraction: "server_legacy",
                    sourceBytes: data.count,
                    wasTruncated: false,
                    pageCount: nil,
                    sheetNames: [],
                    rawData: data
                ),
                fallbackImageData: nil
            )
        case "rtf":
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return textResult(
                attributed.string,
                fileName: safeName,
                mimeType: "application/rtf",
                extraction: "ios_rtf",
                sourceBytes: data.count
            )
        case "csv":
            return textResult(
                try decodedText(data),
                fileName: safeName,
                mimeType: "text/csv",
                extraction: "ios_csv",
                sourceBytes: data.count
            )
        case "txt", "log", "md", "json", "xml":
            return textResult(
                try decodedText(data),
                fileName: safeName,
                mimeType: mimeType(for: safeName),
                extraction: "ios_text",
                sourceBytes: data.count
            )
        default:
            throw AssistantDocumentPreparationError.unsupportedFormat
        }
    }

    private static func preparePDF(data: Data, fileName: String) throws -> ExtractionResult {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw AssistantDocumentPreparationError.unreadableDocument
        }

        var sections: [String] = []
        var usedOCR = false
        var renderedFirstPage: Data?
        var ocrPages = 0
        let pageLimit = min(document.pageCount, maximumPDFPages)

        for index in 0 ..< pageLimit {
            guard let page = document.page(at: index) else { continue }
            var text = normalizedText(page.string ?? "")
            if text.count < 24, ocrPages < maximumOCRPages, let image = renderedImage(for: page) {
                if index == 0 {
                    renderedFirstPage = image.jpegData(compressionQuality: 0.86)
                }
                let recognized = recognizedText(in: image)
                if recognized.count > text.count {
                    text = recognized
                    usedOCR = true
                }
                ocrPages += 1
            }
            if index == 0, renderedFirstPage == nil, text.count < 24, let image = renderedImage(for: page) {
                renderedFirstPage = image.jpegData(compressionQuality: 0.86)
            }
            if !text.isEmpty {
                sections.append("[Страница \(index + 1)]\n\(text)")
            }
            if sections.joined(separator: "\n\n").count >= maximumTextCharacters {
                break
            }
        }

        let bounded = boundedText(sections.joined(separator: "\n\n"))
        guard !bounded.text.isEmpty || renderedFirstPage != nil else {
            throw AssistantDocumentPreparationError.emptyDocument
        }
        return ExtractionResult(
            payload: AssistantPreparedDocumentPayload(
                fileName: fileName,
                mimeType: "application/pdf",
                text: bounded.text,
                extraction: usedOCR ? "ios_pdf_ocr" : "ios_pdf_text",
                sourceBytes: data.count,
                wasTruncated: bounded.truncated || document.pageCount > pageLimit,
                pageCount: document.pageCount,
                sheetNames: [],
                rawData: nil
            ),
            fallbackImageData: bounded.text.count < 24 ? renderedFirstPage : nil
        )
    }

    private static func prepareDOCX(data: Data, fileName: String) throws -> ExtractionResult {
        let archive = try ZIPArchive(data: data)
        var parts = ["word/document.xml"]
        parts += archive.entries.keys
            .filter { $0.hasPrefix("word/header") && $0.hasSuffix(".xml") }
            .sorted()
        parts += archive.entries.keys
            .filter { $0.hasPrefix("word/footer") && $0.hasSuffix(".xml") }
            .sorted()

        var sections: [String] = []
        for path in parts where archive.entries[path] != nil {
            let xml = try safelyExtract(path, from: archive)
            let text = try AssistantWordXMLParser.parse(data: xml)
            if !text.isEmpty { sections.append(text) }
        }
        return textResult(
            sections.joined(separator: "\n\n"),
            fileName: fileName,
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            extraction: "ios_docx",
            sourceBytes: data.count
        )
    }

    private static func prepareXLSX(data: Data, fileName: String) throws -> ExtractionResult {
        let archive = try ZIPArchive(data: data)
        let worksheetPaths = archive.entries.keys
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted(by: naturalPathOrder)
        guard !worksheetPaths.isEmpty else { throw AssistantDocumentPreparationError.unreadableDocument }

        let sharedStrings: [String]
        if archive.entries["xl/sharedStrings.xml"] != nil {
            sharedStrings = try SharedStringsXMLParser.parse(
                data: safelyExtract("xl/sharedStrings.xml", from: archive)
            )
        } else {
            sharedStrings = []
        }
        let workbookNames: [String]
        if archive.entries["xl/workbook.xml"] != nil {
            workbookNames = (try? AssistantWorkbookXMLParser.parse(
                data: safelyExtract("xl/workbook.xml", from: archive)
            )) ?? []
        } else {
            workbookNames = []
        }

        var sections: [String] = []
        var usedSheetNames: [String] = []
        for (index, path) in worksheetPaths.prefix(maximumWorksheets).enumerated() {
            let sheetName = workbookNames.indices.contains(index) ? workbookNames[index] : "Лист \(index + 1)"
            let rows = try AssistantWorksheetTableParser.parse(
                data: safelyExtract(path, from: archive),
                sharedStrings: sharedStrings
            )
            guard !rows.isEmpty else { continue }
            usedSheetNames.append(sheetName)
            sections.append("[Лист: \(sheetName)]\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            if sections.joined(separator: "\n\n").count >= maximumTextCharacters { break }
        }
        let bounded = boundedText(sections.joined(separator: "\n\n"))
        guard !bounded.text.isEmpty else { throw AssistantDocumentPreparationError.emptyDocument }
        return ExtractionResult(
            payload: AssistantPreparedDocumentPayload(
                fileName: fileName,
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                text: bounded.text,
                extraction: "ios_xlsx",
                sourceBytes: data.count,
                wasTruncated: bounded.truncated || worksheetPaths.count > maximumWorksheets,
                pageCount: nil,
                sheetNames: usedSheetNames,
                rawData: nil
            ),
            fallbackImageData: nil
        )
    }

    private static func textResult(
        _ rawText: String,
        fileName: String,
        mimeType: String,
        extraction: String,
        sourceBytes: Int
    ) -> ExtractionResult {
        let bounded = boundedText(rawText)
        return ExtractionResult(
            payload: AssistantPreparedDocumentPayload(
                fileName: fileName,
                mimeType: mimeType,
                text: bounded.text,
                extraction: extraction,
                sourceBytes: sourceBytes,
                wasTruncated: bounded.truncated,
                pageCount: nil,
                sheetNames: [],
                rawData: nil
            ),
            fallbackImageData: nil
        )
    }

    private static func safelyExtract(_ path: String, from archive: ZIPArchive) throws -> Data {
        guard let entry = archive.entries[path],
              entry.uncompressedSize >= 0,
              entry.uncompressedSize <= maximumArchiveEntryBytes else {
            throw AssistantDocumentPreparationError.fileTooLarge
        }
        return try archive.extract(path)
    }

    private static func decodedText(_ data: Data) throws -> String {
        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1251,
            .isoLatin1
        ] {
            if let value = String(data: data, encoding: encoding), !value.isEmpty {
                return value
            }
        }
        throw AssistantDocumentPreparationError.unreadableDocument
    }

    private static func boundedText(_ raw: String) -> (text: String, truncated: Bool) {
        let normalized = normalizedText(raw)
        guard normalized.count > maximumTextCharacters else { return (normalized, false) }
        let headCount = Int(Double(maximumTextCharacters) * 0.78)
        let tailCount = maximumTextCharacters - headCount
        return (
            String(normalized.prefix(headCount))
                + "\n[…часть документа сокращена на устройстве…]\n"
                + String(normalized.suffix(tailCount)),
            true
        )
    }

    private static func normalizedText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let name = URL(fileURLWithPath: raw).lastPathComponent
            .replacingOccurrences(of: #"[\u{0000}-\u{001F}]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "Документ" : name).prefix(140))
    }

    private static func mimeType(for fileName: String) -> String {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "text/plain"
    }

    private static func renderedImage(for page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1_600 / bounds.width, 1_600 / bounds.height, 2.5)
        return page.thumbnail(
            of: CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)),
            for: .mediaBox
        )
    }

    private static func recognizedText(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return normalizedText(lines.joined(separator: "\n"))
    }

    private static func naturalPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private struct ExtractionResult: Sendable {
        let payload: AssistantPreparedDocumentPayload
        let fallbackImageData: Data?
    }
}

nonisolated final class AssistantWordXMLParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var isReadingText = false

    static func parse(data: Data) throws -> String {
        let delegate = AssistantWordXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw AssistantDocumentPreparationError.unreadableDocument }
        return delegate.output
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qName) {
        case "t": isReadingText = true
        case "tab": output += "\t"
        case "br", "cr": output += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingText { output += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName) {
        case "t": isReadingText = false
        case "tc": output += "\t"
        case "p", "tr": output += "\n"
        default: break
        }
    }

    private func localName(_ elementName: String, _ qualifiedName: String?) -> String {
        (qualifiedName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
    }
}

nonisolated final class AssistantWorkbookXMLParser: NSObject, XMLParserDelegate {
    private var names: [String] = []

    static func parse(data: Data) throws -> [String] {
        let delegate = AssistantWorkbookXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw AssistantDocumentPreparationError.unreadableDocument }
        return delegate.names
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "sheet", let name = attributeDict["name"], !name.isEmpty {
            names.append(String(name.prefix(80)))
        }
    }
}

nonisolated final class AssistantWorksheetTableParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentCells: [Int: String] = [:]
    private var currentColumn = 0
    private var currentType = ""
    private var currentValue = ""
    private var currentFormula = ""
    private var readingValue = false
    private var readingFormula = false

    private let maximumRows = 120
    private let maximumColumns = 24

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(data: Data, sharedStrings: [String]) throws -> [[String]] {
        let delegate = AssistantWorksheetTableParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw AssistantDocumentPreparationError.unreadableDocument }
        return delegate.rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row": currentCells = [:]
        case "c":
            currentColumn = columnIndex(from: attributeDict["r"] ?? "")
            currentType = attributeDict["t"] ?? ""
            currentValue = ""
            currentFormula = ""
        case "v", "t": readingValue = true
        case "f": readingFormula = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingValue { currentValue += string }
        if readingFormula { currentFormula += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v", "t": readingValue = false
        case "f": readingFormula = false
        case "c": commitCell()
        case "row": commitRow()
        default: break
        }
    }

    private func commitCell() {
        guard currentColumn > 0, currentColumn <= maximumColumns else { return }
        let raw = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if currentType == "s", let index = Int(raw), sharedStrings.indices.contains(index) {
            value = sharedStrings[index]
        } else if currentType == "b" {
            value = raw == "1" ? "Да" : "Нет"
        } else if !currentFormula.isEmpty {
            value = raw.isEmpty ? "=\(currentFormula)" : "=\(currentFormula) → \(raw)"
        } else {
            value = raw
        }
        if !value.isEmpty { currentCells[currentColumn] = String(value.prefix(600)) }
    }

    private func commitRow() {
        guard rows.count < maximumRows, !currentCells.isEmpty else { return }
        let lastColumn = min(currentCells.keys.max() ?? 0, maximumColumns)
        rows.append((1 ... lastColumn).map { currentCells[$0] ?? "" })
    }

    private func columnIndex(from reference: String) -> Int {
        reference.prefix { $0.isLetter }.reduce(0) { partial, character in
            let value = Int(character.uppercased().unicodeScalars.first?.value ?? 65) - 64
            return partial * 26 + value
        }
    }
}
