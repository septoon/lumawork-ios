import Foundation
import SwiftUI
import UIKit

nonisolated enum GsmPhoneFormatter {
    static let nationalDigitLimit = 10

    struct EditResult {
        let text: String
        let cursorOffset: Int
    }

    static func format(_ value: String) -> String {
        applyMask(to: nationalDigits(from: value))
    }

    static func isComplete(_ value: String) -> Bool {
        nationalDigits(from: value).count == nationalDigitLimit
    }

    static func edit(_ value: String, range: NSRange, replacement: String) -> EditResult {
        let characters = Array(value)
        let start = min(max(0, range.location), characters.count)
        let end = min(start + range.length, characters.count)
        let digitOffsets = characters.indices.filter {
            isDigit(characters[$0]) && !(value.hasPrefix("+7") && $0 == 1)
        }
        var digits = digitOffsets.map { characters[$0] }
        var lower = digitOffsets.filter { $0 < start }.count
        let upper = digitOffsets.filter { $0 < end }.count
        var inserted = replacement.filter(isDigit)

        if replacement.isEmpty, end > start, lower == upper, lower > 0 {
            // Backspace on a separator deletes the preceding national digit.
            lower -= 1
        }

        let replacesNumber = lower == 0 && upper == digits.count
        if replacesNumber {
            inserted = nationalDigits(from: replacement)
            if start == 0, end == characters.count, replacement == "7" || replacement == "8" {
                return EditResult(text: "+7", cursorOffset: 2)
            }
        }

        // Ignore non-digits pasted/typed over an existing selection.
        if !replacement.isEmpty && inserted.isEmpty {
            return EditResult(text: value, cursorOffset: end)
        }

        let capacity = nationalDigitLimit - (digits.count - (upper - lower))
        inserted = String(inserted.prefix(max(0, capacity)))
        digits.replaceSubrange(lower..<upper, with: inserted)
        let formatted = applyMask(to: String(digits))
        let cursorDigitIndex = lower + inserted.count
        let formattedCharacters = Array(formatted)
        let formattedDigitOffsets = formattedCharacters.indices.filter {
            $0 > 1 && isDigit(formattedCharacters[$0])
        }
        let cursor = cursorDigitIndex < formattedDigitOffsets.count
            ? formattedDigitOffsets[cursorDigitIndex]
            : formatted.count
        return EditResult(text: formatted, cursorOffset: cursor)
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func nationalDigits(from value: String) -> String {
        var digits = value.filter(isDigit)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+7"), digits.first == "7" {
            digits.removeFirst()
        } else if digits.count > nationalDigitLimit, digits.first == "7" || digits.first == "8" {
            digits.removeFirst()
        }
        return String(digits.prefix(nationalDigitLimit))
    }

    private static func applyMask(to digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        var result = "+7(" + String(digits.prefix(3))
        if digits.count >= 3 { result += ")" }
        if digits.count > 3 { result += String(digits.dropFirst(3).prefix(3)) }
        if digits.count > 6 { result += "-" + String(digits.dropFirst(6).prefix(2)) }
        if digits.count > 8 { result += "-" + String(digits.dropFirst(8).prefix(2)) }
        return result
    }
}

struct GsmPhoneTextField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .phonePad
        field.textContentType = .telephoneNumber
        field.placeholder = "+7(XXX)XXX-XX-XX"
        field.accessibilityLabel = "Телефон"
        field.accessibilityIdentifier = "gsm-profile-phone"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(named: "AppInk") ?? .label
        field.tintColor = UIColor(named: "AppPrimaryTint") ?? .systemBlue
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let result = GsmPhoneFormatter.edit(textField.text ?? "", range: range, replacement: string)
            textField.text = result.text
            if let position = textField.position(from: textField.beginningOfDocument, offset: result.cursorOffset) {
                textField.selectedTextRange = textField.textRange(from: position, to: position)
            }
            text.wrappedValue = result.text
            return false
        }
    }
}
