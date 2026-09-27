import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

enum AppFormatting {
    static func number(_ value: Double, maximumFractionDigits: Int = 1) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "ru_RU"))
                .precision(.fractionLength(0 ... maximumFractionDigits))
        )
    }

    static func rubles(_ value: Double, maximumFractionDigits: Int = 0) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "ru_RU"))
                .precision(.fractionLength(0 ... maximumFractionDigits))
        ) + " ₽"
    }

    static func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-")
        guard parts.count >= 3 else { return value }
        return "\(parts[2].prefix(2)).\(parts[1]).\(parts[0])"
    }

    static func monthLabel(_ monthKey: String) -> String {
        let months = [
            "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
            "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
        ]
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2, let monthIndex = Int(parts[1]), (1 ... 12).contains(monthIndex) else {
            return monthKey
        }
        return "\(months[monthIndex - 1]) \(parts[0])"
    }

    static func monthNameGenitive(from date: String) -> String {
        let months = [
            "января", "февраля", "марта", "апреля", "мая", "июня",
            "июля", "августа", "сентября", "октября", "ноября", "декабря"
        ]
        let parts = date.split(separator: "-")
        guard parts.count >= 3, let monthIndex = Int(parts[1]), (1 ... 12).contains(monthIndex) else {
            return date
        }
        let day = Int(parts[2].prefix(2)) ?? 0
        return "\(day) \(months[monthIndex - 1])"
    }

    static func monthNameNominative(from date: String) -> String {
        let months = [
            "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
            "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
        ]
        let parts = date.split(separator: "-")
        guard parts.count >= 3, let monthIndex = Int(parts[1]), (1 ... 12).contains(monthIndex) else {
            return date
        }
        let day = Int(parts[2].prefix(2)) ?? 0
        return "\(day) \(months[monthIndex - 1])"
    }
}

enum QRCodeBuilder {
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    static func image(for string: String) -> UIImage? {
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let transform = CGAffineTransform(scaleX: 12, y: 12)
        let scaled = output.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

nonisolated func stringValue(_ value: Any?, default fallback: String = "") -> String {
    if value == nil || value is NSNull {
        return fallback
    }
    if let string = value as? String {
        return string
    }
    return String(describing: value!)
}

func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    default:
        return nil
    }
}

func intValue(_ value: Any?) -> Int? {
    guard let number = doubleValue(value) else {
        return nil
    }
    return Int(number)
}

func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func arrayValue(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

func normalizedDate(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(10).description
}

protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}
