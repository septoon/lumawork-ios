import Foundation

nonisolated func resolvedSimpleOneAdditionalInformation(
    systemValue: String,
    localizedValue: String
) -> String {
    let systemValue = systemValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !systemValue.isEmpty {
        return systemValue
    }
    return localizedValue.trimmingCharacters(in: .whitespacesAndNewlines)
}
