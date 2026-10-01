import Foundation

@main
struct ClientPersonalCommentMatchingTests {
    static func main() {
        let index = ClientPersonalCommentMatchingIndex(entries: [
            .init(id: "global", tin: "7707083893", addresses: [], terminalIDs: []),
            .init(id: "pharmacy", tin: "7707083893", addresses: ["ул. Ленина, 1"], terminalIDs: ["00-A7", "00-A8"]),
            .init(id: "shop", tin: "7707083893", addresses: ["ул. Ленина, 10"], terminalIDs: ["00-B1"]),
            .init(id: "foreign", tin: "500100732259", addresses: [], terminalIDs: ["00-X1"])
        ])

        expect(index.selectedID(tin: "7707083893", address: " УЛ. ЛЕНИНА, 1 ", terminalID: "00-B1") == "pharmacy", "address wins over conflicting terminal")
        expect(index.selectedID(tin: "7707083893", address: "ул. Ленина, 10", terminalID: "") == "shop", "address matching is exact")
        expect(index.selectedID(tin: "7707083893", address: "unknown", terminalID: "00-a8") == "pharmacy", "terminal selects address comment")
        expect(index.selectedID(tin: "7707083893", address: "unknown", terminalID: "") == "global", "global TIN fallback")
        expect(index.selectedID(tin: "", address: "", terminalID: "00-A7") == "pharmacy", "terminal selects comment without TIN")
        expect(index.selectedID(tin: "7707083893", address: "unknown", terminalID: "00-X1") == "global", "foreign TIN terminal cannot replace own global comment")
        expect(index.selectedID(tin: "123", address: "", terminalID: "00-X1") == "foreign", "invalid TIN falls back to terminal")
        expect(ClientPersonalCommentMatchingIndex.normalizedAddress("Йошкар-Ола") == "йошкар-ола", "address normalization keeps й distinct from и")

        expect(ClientPersonalCommentPhoneFormatter.display("+79991234567") == "+7 (999) 123-45-67", "complete phone is masked")
        expect(ClientPersonalCommentPhoneFormatter.display("+7999") == "+7999", "incomplete phone is not masked")
        expect(ClientPersonalCommentPhoneFormatter.canonical("+7 (999) 123-45-67") == "+79991234567", "copied phone is canonical")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ClientPersonalCommentDateCoding.strategy
        let fractionalDate = try! decoder.decode(Date.self, from: Data("\"2026-09-30T00:00:00.123Z\"".utf8))
        let wholeSecondDate = try! decoder.decode(Date.self, from: Data("\"2026-09-30T00:00:00Z\"".utf8))
        expect(abs(fractionalDate.timeIntervalSince(wholeSecondDate) - 0.123) < 0.001, "API fractional seconds decode")
        print("ClientPersonalCommentMatchingTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
