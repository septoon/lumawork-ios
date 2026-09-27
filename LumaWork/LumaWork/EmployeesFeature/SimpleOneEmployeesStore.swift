import Foundation
import Observation

private struct SimpleOneEmployeeDirectory: Codable {
    let employees: [SimpleOneEmployee]
    let totalCount: Int
}

private struct SimpleOneEmployeesSnapshot: Codable {
    let currentUserID: String
    let selectedAddress: SimpleOneEmployeeAddress?
    let savedAddresses: [SimpleOneEmployeeAddress]?
    let employees: [SimpleOneEmployee]
    let totalCount: Int
    let directoriesByAddressID: [String: SimpleOneEmployeeDirectory]?
    let detailCache: [String: SimpleOneEmployee]
}

private struct SavedEmployeeAddressesState: Codable {
    let selectedAddressID: String?
    let addresses: [SimpleOneEmployeeAddress]
}

@MainActor
@Observable
final class SimpleOneEmployeesStore {
    private let service = SimpleOneRequestsService()
    private let legacySavedAddressKey = "simpleone-employees-selected-address"
    private let savedAddressesKey = "simpleone-employees-saved-addresses"
    private let cacheKey: String
    private var employeeLoadID = UUID()
    private var addressLoadID = UUID()
    private var detailCache: [String: SimpleOneEmployee] = [:]
    private var directoriesByAddressID: [String: SimpleOneEmployeeDirectory] = [:]

    private(set) var employees: [SimpleOneEmployee] = []
    private(set) var addressResults: [SimpleOneEmployeeAddress] = []
    private(set) var selectedAddress: SimpleOneEmployeeAddress?
    private(set) var savedAddresses: [SimpleOneEmployeeAddress] = []
    private(set) var currentUserID = ""
    private(set) var totalCount = 0
    private(set) var didBootstrap = false
    var isLoading = false
    var isSearchingAddresses = false
    var errorMessage: String?
    var addressErrorMessage: String?

    init(cacheID: String? = nil) {
        cacheKey = AppOfflineSnapshotStore.scopedKey("simpleone-employees", userID: cacheID)
        guard let snapshot = AppOfflineSnapshotStore.load(
            SimpleOneEmployeesSnapshot.self,
            key: cacheKey
        ) else {
            return
        }
        currentUserID = snapshot.value.currentUserID
        selectedAddress = snapshot.value.selectedAddress
        savedAddresses = snapshot.value.savedAddresses
            ?? snapshot.value.selectedAddress.map { [$0] }
            ?? []
        employees = snapshot.value.employees
        totalCount = snapshot.value.totalCount
        directoriesByAddressID = snapshot.value.directoriesByAddressID ?? [:]
        if directoriesByAddressID.isEmpty,
           let selectedAddress {
            directoriesByAddressID[selectedAddress.id] = SimpleOneEmployeeDirectory(
                employees: employees,
                totalCount: totalCount
            )
        }
        detailCache = snapshot.value.detailCache
    }

    func bootstrap(authKey: String?) async {
        guard !didBootstrap else { return }
        guard let authKey, !authKey.isEmpty else {
            errorMessage = "Войдите в SimpleOne в разделе «Заявки», чтобы открыть сотрудников."
            didBootstrap = true
            return
        }

        errorMessage = nil
        do {
            let currentUser = try await service.fetchCurrentUser(authKey: authKey)
            if !currentUserID.isEmpty, currentUserID != currentUser.sysID {
                employees = []
                totalCount = 0
                detailCache = [:]
                directoriesByAddressID = [:]
                selectedAddress = nil
                savedAddresses = []
            }
            currentUserID = currentUser.sysID

            if let state = loadSavedAddressesState(for: currentUser.sysID) {
                savedAddresses = state.addresses
                selectedAddress = state.selectedAddressID.flatMap { selectedID in
                    state.addresses.first { $0.id == selectedID }
                } ?? state.addresses.first
                applySelectedDirectory()
            } else {
                if !savedAddresses.isEmpty {
                    if let selectedAddress,
                       !savedAddresses.contains(where: { $0.id == selectedAddress.id }) {
                        savedAddresses.append(selectedAddress)
                    }
                    selectedAddress = selectedAddress ?? savedAddresses.first
                    applySelectedDirectory()
                } else if let legacyAddress = loadLegacySavedAddress(for: currentUser.sysID) {
                    savedAddresses = [legacyAddress]
                    selectedAddress = legacyAddress
                    applySelectedDirectory()
                } else {
                    let employee = try await service.fetchEmployeeDetail(
                        sysID: currentUser.sysID,
                        authKey: authKey
                    )
                    detailCache[employee.sysID] = employee
                    if let address = employee.address {
                        savedAddresses = [address]
                        selectedAddress = address
                        applySelectedDirectory()
                    }
                }
                saveAddressesState()
            }

            if selectedAddress == nil {
                errorMessage = "Выберите и сохраните населённый пункт."
            }
            saveSnapshot()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
        didBootstrap = true
    }

    func refresh(authKey: String?, searchText: String) async {
        guard let authKey, !authKey.isEmpty else {
            errorMessage = "Сессия SimpleOne не найдена."
            return
        }
        guard let selectedAddress else {
            return
        }

        let loadID = UUID()
        employeeLoadID = loadID
        isLoading = true
        errorMessage = nil
        defer {
            if employeeLoadID == loadID {
                isLoading = false
            }
        }

        do {
            let response = try await service.fetchEmployees(
                address: selectedAddress,
                searchText: searchText,
                authKey: authKey
            )
            guard !Task.isCancelled,
                  employeeLoadID == loadID,
                  self.selectedAddress?.id == selectedAddress.id else {
                return
            }
            employees = response.employees
            totalCount = response.totalCount
            directoriesByAddressID[selectedAddress.id] = SimpleOneEmployeeDirectory(
                employees: response.employees,
                totalCount: response.totalCount
            )
            saveSnapshot()
        } catch is CancellationError {
            return
        } catch {
            guard employeeLoadID == loadID else { return }
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    func searchAddresses(authKey: String?, query: String) async {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else {
            addressResults = []
            addressErrorMessage = nil
            isSearchingAddresses = false
            return
        }
        guard let authKey, !authKey.isEmpty else {
            addressErrorMessage = "Сессия SimpleOne не найдена."
            return
        }

        let loadID = UUID()
        addressLoadID = loadID
        isSearchingAddresses = true
        addressErrorMessage = nil
        defer {
            if addressLoadID == loadID {
                isSearchingAddresses = false
            }
        }

        do {
            let results = try await service.fetchEmployeeAddressOptions(
                query: normalizedQuery,
                authKey: authKey
            )
            guard !Task.isCancelled, addressLoadID == loadID else { return }
            addressResults = results
        } catch is CancellationError {
            return
        } catch {
            guard addressLoadID == loadID else { return }
            addressErrorMessage = appUserFacingErrorMessage(error)
        }
    }

    func selectAddress(_ address: SimpleOneEmployeeAddress) {
        if let index = savedAddresses.firstIndex(where: { $0.id == address.id }) {
            savedAddresses[index] = address
        } else {
            savedAddresses.append(address)
        }
        selectedAddress = address
        applySelectedDirectory()
        errorMessage = nil
        saveAddressesState()
        saveSnapshot()
        addressResults = []
        addressErrorMessage = nil
    }

    func removeSavedAddress(_ address: SimpleOneEmployeeAddress) {
        savedAddresses.removeAll { $0.id == address.id }
        directoriesByAddressID[address.id] = nil

        if selectedAddress?.id == address.id {
            selectedAddress = savedAddresses.first
            applySelectedDirectory()
        }

        errorMessage = selectedAddress == nil
            ? "Выберите и сохраните населённый пункт."
            : nil
        saveAddressesState()
        saveSnapshot()
    }

    func employeeDetail(
        for employee: SimpleOneEmployee,
        authKey: String?,
        forceRefresh: Bool = false
    ) async throws -> SimpleOneEmployee {
        if !forceRefresh,
           let cached = detailCache[employee.sysID],
           !cached.detailSections.isEmpty {
            return cached
        }
        guard let authKey, !authKey.isEmpty else {
            throw SimpleOneServiceError.missingCredentials
        }

        let detailed = try await service.fetchEmployeeDetail(
            sysID: employee.sysID,
            fallback: employee,
            authKey: authKey
        )
        detailCache[detailed.sysID] = detailed
        if let index = employees.firstIndex(where: { $0.sysID == detailed.sysID }) {
            employees[index] = detailed
        }
        saveSnapshot()
        return detailed
    }

    private func saveSnapshot() {
        AppOfflineSnapshotStore.save(
            SimpleOneEmployeesSnapshot(
                currentUserID: currentUserID,
                selectedAddress: selectedAddress,
                savedAddresses: savedAddresses,
                employees: employees,
                totalCount: totalCount,
                directoriesByAddressID: directoriesByAddressID,
                detailCache: detailCache
            ),
            key: cacheKey
        )
    }

    private func applySelectedDirectory() {
        guard let selectedAddress,
              let directory = directoriesByAddressID[selectedAddress.id] else {
            employees = []
            totalCount = 0
            return
        }
        employees = directory.employees
        totalCount = directory.totalCount
    }

    private func loadSavedAddressesState(for userID: String) -> SavedEmployeeAddressesState? {
        guard let data = UserDefaults.standard.data(
            forKey: addressStorageKey(savedAddressesKey, userID: userID)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(SavedEmployeeAddressesState.self, from: data)
    }

    private func loadLegacySavedAddress(for userID: String) -> SimpleOneEmployeeAddress? {
        guard let data = UserDefaults.standard.data(
            forKey: addressStorageKey(legacySavedAddressKey, userID: userID)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(SimpleOneEmployeeAddress.self, from: data)
    }

    private func saveAddressesState() {
        let state = SavedEmployeeAddressesState(
            selectedAddressID: selectedAddress?.id,
            addresses: savedAddresses
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(
            data,
            forKey: addressStorageKey(savedAddressesKey, userID: currentUserID)
        )
    }

    private func addressStorageKey(_ baseKey: String, userID: String) -> String {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedUserID.isEmpty
            ? baseKey
            : "\(baseKey).\(normalizedUserID)"
    }
}
