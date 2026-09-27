import Foundation
import Observation

@MainActor
@Observable
final class AppNavigationVisibilityStore {
    private let storageKey = "app.navigation.disabled-sections"
    private let defaults = UserDefaults.standard

    private(set) var disabledSectionIDs: Set<String> = []

    init() {
        load()
    }

    var changeToken: String {
        disabledSectionIDs.sorted().joined(separator: "|")
    }

    func visibleCases(isAdmin: Bool) -> [AppNavigationSection] {
        AppNavigationSection.availableCases(isAdmin: isAdmin).filter(isEnabled)
    }

    func isEnabled(_ section: AppNavigationSection) -> Bool {
        !disabledSectionIDs.contains(section.rawValue)
    }

    func canDisable(_ section: AppNavigationSection, isAdmin: Bool) -> Bool {
        guard isEnabled(section) else { return true }
        return visibleCases(isAdmin: isAdmin).count > 1
    }

    func setEnabled(_ section: AppNavigationSection, _ isEnabled: Bool, isAdmin: Bool) {
        var nextDisabled = disabledSectionIDs
        if isEnabled {
            nextDisabled.remove(section.rawValue)
        } else {
            nextDisabled.insert(section.rawValue)
        }

        let nextVisible = AppNavigationSection.availableCases(isAdmin: isAdmin).filter {
            !nextDisabled.contains($0.rawValue)
        }
        guard !nextVisible.isEmpty else { return }

        disabledSectionIDs = nextDisabled
        save()
    }

    func firstVisibleCase(isAdmin: Bool) -> AppNavigationSection {
        visibleCases(isAdmin: isAdmin).first ?? .home
    }

    private func load() {
        guard let raw = defaults.array(forKey: storageKey) as? [String] else {
            disabledSectionIDs = []
            return
        }
        disabledSectionIDs = Set(raw)
    }

    private func save() {
        defaults.set(disabledSectionIDs.sorted(), forKey: storageKey)
    }
}
