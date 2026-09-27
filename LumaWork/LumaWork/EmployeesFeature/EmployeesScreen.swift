import SwiftUI

struct EmployeesScreen: View {
    let simpleOneStore: SimpleOneRequestsStore
    let workScheduleStore: WorkScheduleStore
    let profileCity: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: SimpleOneEmployeesStore
    @State private var searchText = ""
    @State private var isAddressPickerPresented = false

    init(
        simpleOneStore: SimpleOneRequestsStore,
        store: SimpleOneEmployeesStore,
        workScheduleStore: WorkScheduleStore,
        profileCity: String?
    ) {
        self.simpleOneStore = simpleOneStore
        self.workScheduleStore = workScheduleStore
        self.profileCity = profileCity
        _store = State(initialValue: store)
    }

    init(simpleOneStore: SimpleOneRequestsStore) {
        self.simpleOneStore = simpleOneStore
        self.workScheduleStore = WorkScheduleStore()
        self.profileCity = nil
        _store = State(initialValue: SimpleOneEmployeesStore())
    }

    private var searchTaskID: String {
        "\(store.selectedAddress?.sysID ?? "")|\(searchText)"
    }

    private var groups: [EmployeeDirectoryGroup] {
        let grouped = Dictionary(grouping: store.employees) { employee in
            let source = firstNonEmpty(employee.lastName, employee.fullName, employee.login)
            return source.first.map { String($0).uppercased(with: AppLocale.russian) } ?? "#"
        }
        return grouped
            .map { EmployeeDirectoryGroup(letter: $0.key, employees: $0.value) }
            .sorted {
                $0.letter.localizedStandardCompare($1.letter) == .orderedAscending
            }
    }

    var body: some View {
        AppScreen {
            VStack(alignment: .leading, spacing: 18) {
                if !simpleOneStore.isAuthorized {
                    AppEmptyState(
                        title: "SimpleOne не подключён",
                        message: "Войдите в SimpleOne на экране «Заявки», затем вернитесь к сотрудникам.",
                        systemName: "person.crop.circle.badge.exclamationmark"
                    )
                } else if !store.didBootstrap || store.isLoading {
                    EmployeeDirectoryLoadingView()
                } else {
                    if let address = store.selectedAddress {
                        EmployeeDirectoryHero(
                            address: address,
                            employees: store.employees,
                            totalCount: store.totalCount
                        ) {
                            AppHaptics.trigger(.expandCollapse)
                            isAddressPickerPresented = true
                        }
                        .depthStackPrimary(reduceMotion: reduceMotion)
                    }

                    if let errorMessage = store.errorMessage {
                        AppNoticeBanner(
                            text: errorMessage,
                            tint: AppTheme.dangerTint,
                            isCritical: true
                        )
                        .depthStackSecondary()
                    }

                    if store.didBootstrap, store.selectedAddress == nil {
                        ContentUnavailableView(
                            "Выберите населённый пункт",
                            systemImage: "mappin.and.ellipse",
                            description: Text("Откройте фильтр вверху экрана и сохраните населённый пункт.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .depthStackSecondary()
                    } else if store.didBootstrap,
                              store.selectedAddress != nil,
                              store.employees.isEmpty {
                        ContentUnavailableView(
                            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Сотрудников пока нет"
                                : "Результатов пока нет",
                            systemImage: "person.2.slash",
                            description: Text(
                                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "Обновите список или выберите другой населённый пункт."
                                    : "Измените запрос, повторите поиск или выберите другой населённый пункт."
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .depthStackSecondary()
                    } else if !groups.isEmpty {
                        EmployeeAlphabetDirectory(
                            groups: groups,
                            currentUserID: store.currentUserID,
                            store: store,
                            authKey: simpleOneStore.browserAuthKey
                        )
                        .depthStackSecondary()
                    }
                }
            }
        }
        .navigationTitle("Сотрудники")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeSearch(
            text: $searchText,
            prompt: "Поиск сотрудников",
            isEnabled: simpleOneStore.isAuthorized
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if simpleOneStore.isAuthorized {
                    NavigationLink {
                        WorkScheduleScreen(
                            simpleOneStore: simpleOneStore,
                            store: workScheduleStore,
                            profileCity: profileCity
                        )
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("График работы")
                }
            }
        }
        .refreshable {
            if simpleOneStore.isAuthorized {
                await store.refresh(
                    authKey: simpleOneStore.browserAuthKey,
                    searchText: searchText
                )
            }
        }
        .sheet(isPresented: $isAddressPickerPresented) {
            NavigationStack {
                EmployeeAddressPickerScreen(
                    store: store,
                    authKey: simpleOneStore.browserAuthKey
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: simpleOneStore.isAuthorized) {
            guard simpleOneStore.isAuthorized else { return }
            await store.bootstrap(authKey: simpleOneStore.browserAuthKey)
            if store.selectedAddress != nil {
                await store.refresh(
                    authKey: simpleOneStore.browserAuthKey,
                    searchText: searchText
                )
            }
        }
        .task(id: searchTaskID) {
            guard simpleOneStore.isAuthorized,
                  store.didBootstrap,
                  store.selectedAddress != nil else { return }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await store.refresh(
                authKey: simpleOneStore.browserAuthKey,
                searchText: searchText
            )
        }
    }
}

private struct EmployeeDirectoryGroup: Identifiable {
    let letter: String
    let employees: [SimpleOneEmployee]

    var id: String { letter }
}

private struct EmployeeDirectoryHero: View {
    let address: SimpleOneEmployeeAddress
    let employees: [SimpleOneEmployee]
    let totalCount: Int
    let selectAddress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("КОМАНДА")
                        .font(.caption.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.68))

                    Text(address.title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if !address.region.isEmpty {
                        Text(address.region)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(totalCount.formatted())
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(employeeCountTitle(totalCount))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            HStack(spacing: 14) {
                EmployeeClusterGlyph(employees: employees)

                Button(action: selectAddress) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                        Text("Сменить населённый пункт")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

        }
        .padding(20)
        .background(AppTheme.heroGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow.opacity(0.9), radius: 18, x: 0, y: 10)
    }

    private func employeeCountTitle(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if (11 ... 14).contains(mod100) { return "сотрудников" }
        switch mod10 {
        case 1: return "сотрудник"
        case 2 ... 4: return "сотрудника"
        default: return "сотрудников"
        }
    }
}

private struct EmployeeClusterGlyph: View {
    let employees: [SimpleOneEmployee]

    var body: some View {
        HStack(spacing: -11) {
            ForEach(Array(employees.prefix(4).enumerated()), id: \.element.id) { index, employee in
                Text(employee.initials)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(employeeAccentColor(employee, offset: index), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 2))
                    .zIndex(Double(10 - index))
            }

            if employees.count > 4 {
                Text("+\(employees.count - 4)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.24), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
            }
        }
        .frame(minWidth: 38, alignment: .leading)
        .accessibilityHidden(true)
    }
}

private struct EmployeeAlphabetDirectory: View {
    let groups: [EmployeeDirectoryGroup]
    let currentUserID: String
    let store: SimpleOneEmployeesStore
    let authKey: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                EmployeeLetterHeader(letter: group.letter, count: group.employees.count)

                ForEach(Array(group.employees.enumerated()), id: \.element.id) { index, employee in
                    NavigationLink {
                        EmployeeDetailScreen(
                            employee: employee,
                            store: store,
                            authKey: authKey
                        )
                    } label: {
                        EmployeeDirectoryRow(
                            employee: employee,
                            isCurrentUser: employee.sysID == currentUserID
                        )
                    }
                    .buttonStyle(.plain)

                    if index < group.employees.count - 1 {
                        Divider()
                            .padding(.leading, 82)
                    }
                }

                if groupIndex < groups.count - 1 {
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
        .background(AppTheme.panelSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow.opacity(0.58), radius: 11, x: 0, y: 6)
    }
}

private struct EmployeeLetterHeader: View {
    let letter: String
    let count: Int

    var body: some View {
        HStack(spacing: 11) {
            Text(letter)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.secondaryTint)
                .frame(width: 34)

            Capsule()
                .fill(AppTheme.secondaryTint.opacity(0.26))
                .frame(height: 1)

            Text(count.formatted())
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.mutedTint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

private struct EmployeeDirectoryRow: View {
    let employee: SimpleOneEmployee
    let isCurrentUser: Bool

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                Text(employee.initials)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(employeeAccentColor(employee), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                if employee.isLocked == true {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(AppTheme.dangerTint, in: Circle())
                        .overlay(Circle().stroke(AppTheme.performancePanelFill, lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(employee.fullName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(2)

                    if isCurrentUser {
                        Text("ВЫ")
                            .font(.system(size: 9, weight: .black))
                            .tracking(0.6)
                            .foregroundStyle(AppTheme.primaryTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AppTheme.primaryTint.opacity(0.13), in: Capsule())
                    }
                }

                Text(employee.roleText)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedTint)
                    .lineLimit(1)

                if !employee.login.isEmpty {
                    Text(employee.login)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedTint.opacity(0.82))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.mutedTint.opacity(0.66))
                .frame(width: 28, height: 28)
                .background(AppTheme.ghostFill.opacity(0.55), in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct EmployeeDirectoryLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonPlaceholder(cornerRadius: 5)
                            .frame(width: 68, height: 12)
                        SkeletonPlaceholder(cornerRadius: 9)
                            .frame(width: 176, height: 36)
                        SkeletonPlaceholder(cornerRadius: 6)
                            .frame(width: 122, height: 16)
                    }
                    Spacer()
                    SkeletonPlaceholder(cornerRadius: 10)
                        .frame(width: 54, height: 52)
                }

                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonPlaceholder(cornerRadius: 19)
                            .frame(width: 38, height: 38)
                    }
                    SkeletonPlaceholder(cornerRadius: 21)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
            }
            .padding(20)
            .background(AppTheme.heroGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))

            VStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    HStack(spacing: 13) {
                        SkeletonPlaceholder(cornerRadius: 17)
                            .frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonPlaceholder(cornerRadius: 6)
                                .frame(width: index.isMultiple(of: 2) ? 148 : 174, height: 17)
                            SkeletonPlaceholder(cornerRadius: 5)
                                .frame(width: 108, height: 14)
                            SkeletonPlaceholder(cornerRadius: 4)
                                .frame(width: 82, height: 11)
                        }
                        Spacer()
                        SkeletonPlaceholder(cornerRadius: 14)
                            .frame(width: 28, height: 28)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 82)

                    if index < 6 {
                        Divider().padding(.leading, 82)
                    }
                }
            }
            .background(AppTheme.panelSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружается список сотрудников")
    }
}

private struct EmployeeAddressPickerScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: SimpleOneEmployeesStore
    let authKey: String?
    @State private var searchText = ""

    var body: some View {
        addressPickerContent
            .navigationTitle("Адрес сотрудников")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeSearch(text: $searchText, prompt: "Например, Алушта")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton {
                        dismiss()
                    }
                }
            }
            .task(id: searchText) {
                await searchAddresses()
            }
    }

    private var addressPickerContent: some View {
        AppScreen {
            savedAddressesContent

            AppSectionHeader(
                title: "Населённый пункт",
                caption: "Найдите и добавьте ещё один адрес"
            )

            addressSearchStatusContent
            addressResultsContent
        }
    }

    @ViewBuilder
    private var savedAddressesContent: some View {
        AppSectionHeader(
            title: "Сохранённые адреса",
            caption: "Переключайтесь между каталогами или удаляйте ненужные"
        )

        if store.savedAddresses.isEmpty {
            ContentUnavailableView(
                "Адресов пока нет",
                systemImage: "mappin.slash",
                description: Text("Найдите населённый пункт через строку поиска.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.savedAddresses.enumerated()), id: \.element.id) { index, address in
                    EmployeeAddressRow(
                        address: address,
                        isSelected: address.id == store.selectedAddress?.id,
                        action: {
                            AppHaptics.trigger(.expandCollapse)
                            store.selectAddress(address)
                            dismiss()
                        },
                        remove: {
                            AppHaptics.trigger(.error)
                            store.removeSavedAddress(address)
                        }
                    )

                    if index < store.savedAddresses.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(AppTheme.panelSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var addressSearchStatusContent: some View {
        if store.isSearchingAddresses {
            AppLoadingView(title: "Ищу в справочнике SimpleOne")
        }

        if let error = store.addressErrorMessage {
            AppNoticeBanner(text: error, tint: AppTheme.dangerTint, isCritical: true)
        }
    }

    @ViewBuilder
    private var addressResultsContent: some View {
        if !store.addressResults.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(store.addressResults.enumerated()), id: \.element.id) { index, address in
                    EmployeeAddressRow(
                        address: address,
                        isSelected: address.id == store.selectedAddress?.id
                    ) {
                        AppHaptics.trigger(.expandCollapse)
                        store.selectAddress(address)
                        dismiss()
                    }

                    if index < store.addressResults.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(AppTheme.panelSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        } else if !store.isSearchingAddresses,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                  store.addressErrorMessage == nil {
            ContentUnavailableView(
                "Ничего не найдено",
                systemImage: "mappin.slash",
                description: Text("Проверьте название населённого пункта.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func searchAddresses() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            await store.searchAddresses(authKey: authKey, query: "")
            return
        }
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await store.searchAddresses(authKey: authKey, query: query)
    }
}

private struct EmployeeAddressRow: View {
    let address: SimpleOneEmployeeAddress
    let isSelected: Bool
    let action: () -> Void
    let remove: (() -> Void)?

    init(
        address: SimpleOneEmployeeAddress,
        isSelected: Bool,
        action: @escaping () -> Void,
        remove: (() -> Void)? = nil
    ) {
        self.address = address
        self.isSelected = isSelected
        self.action = action
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 13) {
                    addressIcon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(address.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        if !address.subtitle.isEmpty {
                            Text(address.subtitle)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedTint)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(isSelected ? .body : .caption.weight(.bold))
                        .foregroundStyle(isSelected ? AppTheme.primaryTint : AppTheme.mutedTint)
                }
                .padding(.leading, 14)
                .padding(.trailing, remove == nil ? 14 : 10)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let remove {
                Divider()
                    .frame(height: 32)

                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.dangerTint)
                .accessibilityLabel("Удалить \(address.title) из сохранённых")
                .padding(.horizontal, 4)
            }
        }
    }

    private var addressIcon: some View {
        Image(systemName: "location.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(isSelected ? .white : AppTheme.secondaryTint)
            .frame(width: 38, height: 38)
            .background(
                isSelected ? AppTheme.secondaryTint : AppTheme.secondaryTint.opacity(0.12),
                in: Circle()
            )
    }
}

private struct EmployeeDetailScreen: View {
    @Environment(\.openURL) private var openURL

    @State private var employee: SimpleOneEmployee
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSection: SimpleOneEmployeeSection?

    let store: SimpleOneEmployeesStore
    let authKey: String?

    init(
        employee: SimpleOneEmployee,
        store: SimpleOneEmployeesStore,
        authKey: String?
    ) {
        _employee = State(initialValue: employee)
        self.store = store
        self.authKey = authKey
    }

    var body: some View {
        AppScreen {
            EmployeeDetailHero(employee: employee)

            if !employee.phone.isEmpty || !employee.email.isEmpty {
                EmployeeQuickActionsBar(
                    employee: employee,
                    call: callEmployee,
                    writeEmail: emailEmployee
                )
            }

            if isLoading && employee.detailSections.isEmpty {
                AppLoadingView(title: "Загружаю полную информацию")
            }

            if let errorMessage {
                AppNoticeBanner(
                    text: errorMessage,
                    tint: AppTheme.dangerTint,
                    isCritical: true
                )
            }

            if !employee.detailSections.isEmpty {
                EmployeeInformationIndex(sections: employee.detailSections) { section in
                    AppHaptics.trigger(.expandCollapse)
                    selectedSection = section
                }
            }
        }
        .navigationTitle(employee.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .appSidebarBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.trigger()
                    Task { await loadDetail(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("Обновить информацию о сотруднике")
            }
        }
        .task {
            await loadDetail()
        }
        .sheet(item: $selectedSection) { section in
            EmployeeSectionDetailSheet(section: section)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func loadDetail(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            employee = try await store.employeeDetail(
                for: employee,
                authKey: authKey,
                forceRefresh: forceRefresh
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = appUserFacingErrorMessage(error)
        }
    }

    private func callEmployee() {
        let phone = employee.phone.filter { $0.isNumber || $0 == "+" }
        guard !phone.isEmpty, let url = URL(string: "tel:\(phone)") else { return }
        AppHaptics.trigger()
        openURL(url)
    }

    private func emailEmployee() {
        let email = employee.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, let url = URL(string: "mailto:\(email)") else { return }
        AppHaptics.trigger()
        openURL(url)
    }
}

private struct EmployeeDetailHero: View {
    let employee: SimpleOneEmployee

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Text(employee.initials)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(employeeAccentColor(employee), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.34), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(employee.fullName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(employee.roleText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))

                    if !employee.login.isEmpty {
                        Text(employee.login)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.64))
                    }
                }

                Spacer(minLength: 0)
            }

            if let tenure = employeeTenureText(employee) {
                EmployeeTenureSummary(text: tenure)
            }

            HStack(spacing: 8) {
                if let address = employee.address {
                    EmployeeHeroBadge(icon: "location.fill", text: address.title)
                }
                if employee.isActive == false {
                    EmployeeHeroBadge(icon: "person.crop.circle.badge.xmark", text: "Уволен")
                } else if employee.isActive == true {
                    EmployeeHeroBadge(icon: "checkmark.seal.fill", text: "Действующий")
                }
                if employee.isLocked == true {
                    EmployeeHeroBadge(icon: "lock.fill", text: "Доступ заблокирован")
                }
            }
        }
        .padding(20)
        .background(AppTheme.accentGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct EmployeeTenureSummary: View {
    let text: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "calendar.badge.clock")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("СТАЖ")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.62))

                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct EmployeeHeroBadge: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.13), in: Capsule())
    }
}

private struct EmployeeQuickActionsBar: View {
    let employee: SimpleOneEmployee
    let call: () -> Void
    let writeEmail: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if !employee.phone.isEmpty {
                EmployeeQuickAction(
                    title: "Позвонить",
                    value: employee.phone,
                    icon: "phone.fill",
                    tint: AppTheme.primaryTint,
                    action: call
                )
            }

            if !employee.phone.isEmpty && !employee.email.isEmpty {
                Divider()
                    .frame(height: 46)
                    .padding(.horizontal, 8)
            }

            if !employee.email.isEmpty {
                EmployeeQuickAction(
                    title: "Написать",
                    value: employee.email,
                    icon: "envelope.fill",
                    tint: AppTheme.secondaryTint,
                    action: writeEmail
                )
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct EmployeeQuickAction: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text(value)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EmployeeInformationIndex: View {
    let sections: [SimpleOneEmployeeSection]
    let select: (SimpleOneEmployeeSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("РАЗДЕЛЫ ИНФОРМАЦИИ")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(AppTheme.mutedTint)

                Spacer()

                Text(sections.count.formatted())
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.primaryTint)
            }
            .padding(.bottom, 6)

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Button {
                    select(section)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: employeeSectionIcon(section.title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(employeeSectionTint(index))
                            .frame(width: 38, height: 38)
                            .background(employeeSectionTint(index).opacity(0.13), in: Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(2)

                            Text(sectionSummary(section))
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedTint)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text(section.fields.count.formatted())
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(AppTheme.mutedTint)
                            .frame(minWidth: 24)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.mutedTint.opacity(0.72))
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < sections.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
    }

    private func sectionSummary(_ section: SimpleOneEmployeeSection) -> String {
        section.fields
            .prefix(2)
            .map(\.title)
            .joined(separator: " · ")
    }
}

private struct EmployeeSectionDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let section: SimpleOneEmployeeSection

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("ДОСЬЕ СОТРУДНИКА")
                                .font(.caption.weight(.bold))
                                .tracking(1.7)
                                .foregroundStyle(AppTheme.primaryTint)

                            Text(section.title)
                                .font(.system(.title, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.ink)

                            Text("\(section.fields.count.formatted()) \(employeeFieldCountTitle(section.fields.count))")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedTint)
                        }
                        .padding(.bottom, 18)

                        Rectangle()
                            .fill(AppTheme.primaryTint)
                            .frame(width: 54, height: 3)
                            .padding(.bottom, 10)

                        ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                            HStack(alignment: .top, spacing: 14) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(AppTheme.primaryTint)
                                    .frame(width: 24, alignment: .leading)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(field.title.uppercased(with: AppLocale.russian))
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.7)
                                        .foregroundStyle(AppTheme.mutedTint)

                                    AppSelectableText(
                                        text: field.value,
                                        textStyle: .body,
                                        color: AppTheme.ink
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 14)

                            if index < section.fields.count - 1 {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private func employeeSectionIcon(_ title: String) -> String {
    let normalized = title.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: AppLocale.russian
    )
    if normalized.contains("контакт") || normalized.contains("связ") {
        return "phone.fill"
    }
    if normalized.contains("работ") || normalized.contains("служ") || normalized.contains("должност") {
        return "briefcase.fill"
    }
    if normalized.contains("адрес") || normalized.contains("мест") {
        return "mappin.and.ellipse"
    }
    if normalized.contains("доступ") || normalized.contains("учет") {
        return "key.fill"
    }
    if normalized.contains("личн") || normalized.contains("персон") {
        return "person.text.rectangle"
    }
    return "text.alignleft"
}

private func employeeSectionTint(_ index: Int) -> Color {
    let palette = [
        AppTheme.primaryTint,
        AppTheme.secondaryTint,
        Color(red: 0.34, green: 0.49, blue: 0.66),
        Color(red: 0.55, green: 0.39, blue: 0.62)
    ]
    return palette[index % palette.count]
}

private func employeeFieldCountTitle(_ count: Int) -> String {
    let mod10 = count % 10
    let mod100 = count % 100
    if mod10 == 1, mod100 != 11 {
        return "поле"
    }
    if (2 ... 4).contains(mod10), !(12 ... 14).contains(mod100) {
        return "поля"
    }
    return "полей"
}

private func employeeTenureText(
    _ employee: SimpleOneEmployee,
    relativeTo now: Date = Date()
) -> String? {
    guard let rawHireDate = employeeHireDateText(employee),
          let hireDate = parseEmployeeDate(rawHireDate) else {
        return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = AppLocale.russian
    calendar.timeZone = .current

    let startDate = calendar.startOfDay(for: hireDate)
    let endDate = calendar.startOfDay(for: now)
    guard startDate <= endDate else { return nil }

    let components = calendar.dateComponents(
        [.year, .month, .day],
        from: startDate,
        to: endDate
    )
    let years = components.year ?? 0
    let months = components.month ?? 0
    let days = components.day ?? 0

    var parts: [String] = []
    if years > 0 {
        parts.append(employeeTenureUnit(years, one: "год", few: "года", many: "лет"))
    }
    if months > 0 {
        parts.append(employeeTenureUnit(months, one: "месяц", few: "месяца", many: "месяцев"))
    }
    if days > 0 || parts.isEmpty {
        parts.append(employeeTenureUnit(days, one: "день", few: "дня", many: "дней"))
    }
    return parts.joined(separator: " ")
}

private func employeeHireDateText(_ employee: SimpleOneEmployee) -> String? {
    employee.detailSections
        .lazy
        .flatMap(\.fields)
        .first { field in
            let title = normalizedEmployeeFieldKey(field.title)
            let systemName = normalizedEmployeeFieldKey(field.systemName)

            return title.contains("дата приема")
                || title.contains("прием на работу")
                || title.contains("дата трудоустройства")
                || title.contains("дата начала работы")
                || systemName.contains("hire_date")
                || systemName.contains("employment_date")
                || systemName.contains("employment_start")
                || systemName.contains("work_start")
        }?
        .value
}

private func normalizedEmployeeFieldKey(_ raw: String) -> String {
    raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(with: AppLocale.russian)
        .replacingOccurrences(of: "ё", with: "е")
}

private func parseEmployeeDate(_ raw: String) -> Date? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: value) {
        return date
    }
    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: value) {
        return date
    }

    let formats = [
        "dd.MM.yyyy",
        "dd.MM.yyyy HH:mm",
        "dd.MM.yyyy HH:mm:ss",
        "yyyy-MM-dd",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "d MMMM yyyy"
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.russian
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        formatter.isLenient = false
        if let date = formatter.date(from: value) {
            return date
        }
    }
    return nil
}

private func employeeTenureUnit(
    _ value: Int,
    one: String,
    few: String,
    many: String
) -> String {
    let mod10 = value % 10
    let mod100 = value % 100
    let noun: String
    if mod10 == 1, mod100 != 11 {
        noun = one
    } else if (2 ... 4).contains(mod10), !(12 ... 14).contains(mod100) {
        noun = few
    } else {
        noun = many
    }
    return "\(value) \(noun)"
}

private func employeeAccentColor(_ employee: SimpleOneEmployee, offset: Int = 0) -> Color {
    let palette: [Color] = [
        AppTheme.primaryTint,
        AppTheme.secondaryTint,
        Color(red: 0.34, green: 0.49, blue: 0.66),
        Color(red: 0.55, green: 0.39, blue: 0.62),
        Color(red: 0.35, green: 0.56, blue: 0.52)
    ]
    let scalarSum = employee.sysID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[(scalarSum + offset) % palette.count]
}
