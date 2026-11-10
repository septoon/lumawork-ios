#!/usr/bin/env python3
"""Check the public iOS/Android release-feed contract using the app's real parser."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'LumaWork/LumaWork/AdminApplicationFeature.swift').read_text()
models = 'import Foundation\n' + source.split('// MARK: - Catalog models', 1)[1].split('// MARK: - Catalog loading', 1)[0]
tests = r'''
import Foundation

@main
struct CatalogTests {
    static func main() throws {
        let ios = Data(#"{"apps":[{"bundleIdentifier":"other.app","versions":[]},{"bundleIdentifier":"septon.LumaWork","versions":[{"version":"3.0.40","buildVersion":148,"date":"2026-11-10T09:00:00.123Z","downloadURL":"https://app.lumastack.ru/releases/current.ipa","size":26000000,"minOSVersion":"26.2","localizedDescription":"Описание обновления"},{"version":"3.0.39","buildVersion":"147","date":"2026-11-09T21:25:27Z"}]}]}"#.utf8)
        let releases = try AdminApplicationCatalogParser.ios(ios)
        precondition(releases.count == 2)
        precondition(releases[0].version == "3.0.40" && releases[0].build == "148")
        precondition(releases[0].minimumSystem == "iOS 26.2+")
        precondition(releases[0].notes == "Описание обновления")
        precondition(releases.allSatisfy { $0.publishedAt != nil })
        precondition(releases[0].downloadURL?.scheme == "https")
        precondition(releases[1].downloadURL == nil && releases[1].sizeBytes == nil)

        let latest = Data(#"{"applicationId":"ru.lumastack.lumawork","versionName":"0.2.1","versionCode":69,"publishedAt":"2026-11-09T21:23:42Z","downloadUrl":"https://app.lumastack.ru/android/releases/current.apk","changelog":["Первое изменение","Второе изменение"],"minSdk":26,"sha256":"hash"}"#.utf8)
        let history = Data(#"[{"applicationId":"ru.lumastack.lumawork","versionName":"0.2.1","versionCode":69},{"applicationId":"ru.lumastack.lumawork","versionName":"0.2.0","versionCode":68},{"applicationId":"other.app","versionName":"99","versionCode":999}]"#.utf8)
        let android = try AdminApplicationCatalogParser.android(latest: latest, history: history)
        precondition(android.count == 2, "Keep current release first, remove duplicates and other apps")
        precondition(android[0].build == "69" && android[1].build == "68")
        precondition(android[0].minimumSystem == "API 26+")
        precondition(android[0].notes == "Первое изменение\nВторое изменение")
        precondition(android[0].checksum == "hash")
        let withoutHistory = try AdminApplicationCatalogParser.android(latest: latest, history: nil)
        precondition(withoutHistory.count == 1)

        let cachedFallback = try AdminApplicationCatalogParser.android(latest: latest, history: nil, cachedHistory: android)
        precondition(cachedFallback.count == 2 && cachedFallback[1].build == "68", "A history outage must retain cached releases")
        do {
            _ = try AdminApplicationCatalogParser.android(latest: latest, history: Data("{}".utf8), cachedHistory: android)
            preconditionFailure("Malformed history must be reported, not silently accepted as empty")
        } catch AdminApplicationCatalogParser.CatalogError.invalidCatalog {}

        let invalidLink = Data(#"{"apps":[{"bundleIdentifier":"septon.LumaWork","versions":[{"version":"1","downloadURL":"javascript:alert(1)"}]}]}"#.utf8)
        let invalidLinks = try AdminApplicationCatalogParser.ios(invalidLink)
        precondition(invalidLinks[0].downloadURL == nil)
        do {
            _ = try AdminApplicationCatalogParser.ios(Data(#"{"apps":[{"bundleIdentifier":"other.app","versions":[]}]}"#.utf8))
            preconditionFailure("Must not substitute another app")
        } catch AdminApplicationCatalogParser.CatalogError.invalidCatalog {}

        let snapshot = AdminApplicationCatalog(platform: .ios, releases: releases, checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cached = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(AdminApplicationCatalog.self, from: cached)
        precondition(restored.releases == releases && restored.latest?.build == "148")
        print("Application release feeds, dates, links, history deduplication and cache: PASS")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lumawork-app-catalog-') as directory:
    path = Path(directory)
    (path / 'Models.swift').write_text(models)
    (path / 'Tests.swift').write_text(tests)
    subprocess.run(['swiftc', str(path / 'Models.swift'), str(path / 'Tests.swift'), '-o', str(path / 'tests')], check=True)
    subprocess.run([str(path / 'tests')], check=True)
