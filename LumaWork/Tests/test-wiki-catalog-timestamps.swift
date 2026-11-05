func expect(_ actual: String, _ expected: String) {
    guard actual == expected else { print("FAIL: \(actual), expected \(expected)"); exit(1) }
}
let expected = ProcessInfo.processInfo.environment["TZ"] == "UTC" ? "Каталог обновлен 04.11.2026 в 17:24" : "Каталог обновлен 04.11.2026 в 20:24"
let snapshotID = "20261104T100848Z"
let published = "2026-11-04T17:24:31.096Z"
let subject = CatalogSubject(snapshotID: snapshotID, catalogUpdatedAt: published)
expect(subject.catalogUpdateMessage, expected)
expect(CatalogSubject(snapshotID: snapshotID, catalogUpdatedAt: nil).catalogUpdateMessage, "Дата обновления каталога неизвестна.")
expect(CatalogSubject(snapshotID: snapshotID, catalogUpdatedAt: "invalid").catalogUpdateMessage, "Дата обновления каталога неизвестна.")
expect(CatalogSubject(snapshotID: snapshotID, catalogUpdatedAt: "2026-11-04T20:24:31+03:00").catalogUpdateMessage, expected)
let health = try JSONDecoder().decode(WikiHealthResponse.self, from: Data("{\"snapshotId\":\"20261104T100848Z\",\"updatedAt\":\"2026-11-04T17:24:31.096Z\"}".utf8))
expect(health.updatedAt ?? "", published)
private let oldCache = try JSONDecoder().decode(WikiSearchSnapshot.self, from: Data("{\"snapshotID\":\"20261104T100848Z\",\"query\":\"VPN\",\"results\":[]}".utf8))
expect(CatalogSubject(snapshotID: oldCache.snapshotID, catalogUpdatedAt: oldCache.catalogUpdatedAt).catalogUpdateMessage, "Дата обновления каталога неизвестна.")
private let cache = WikiSearchSnapshot(catalogUpdatedAt: published, query: "VPN", snapshotID: snapshotID, results: [])
private let restored = try JSONDecoder().decode(WikiSearchSnapshot.self, from: JSONEncoder().encode(cache))
expect(restored.catalogUpdatedAt ?? "", published)
print("Wiki catalog timestamps: 7 checks passed (\(TimeZone.current.identifier))")
