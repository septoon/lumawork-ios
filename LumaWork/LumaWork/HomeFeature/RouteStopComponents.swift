import SwiftUI
import UniformTypeIdentifiers

struct RouteStopEditorSelection: Identifiable {
    let stop: RouteStop
    let pointNumber: Int
    let suggestions: [String]
    let requiresOfficeSelection: Bool

    var id: String { stop.id }
}

struct RouteTimelineCard: View {
    let stops: [RouteStop]
    let startEndpointKind: RouteEndpointKind
    let finishEndpointKind: RouteEndpointKind
    let isHomeEndpointAvailable: Bool
    @Binding var draggedStopID: String?
    let onEditStop: (RouteStop, Int) -> Void
    let onDropStop: (String, String) -> Bool
    let onAddStop: () -> Void
    let canRemoveStop: (Int) -> Bool
    let onRemoveStop: (RouteStop) -> Void
    let onEndpointSelect: (RouteEndpointRole, RouteEndpointKind) -> Void
    let onCopyEndpoint: (RouteEndpointKind) -> Void

    private var middleStops: [(offset: Int, element: RouteStop)] {
        Array(stops.enumerated().dropFirst().dropLast())
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 0) {
                endpointSection(
                    title: "Старт",
                    role: .start,
                    selected: startEndpointKind
                )

                routeDivider

                if middleStops.isEmpty {
                    Button {
                        AppHaptics.trigger()
                        onAddStop()
                    } label: {
                        Label("Добавить точку", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                            .frame(maxWidth: .infinity, minHeight: HomeLayout.routeEmptyHeight)
                    }
                    .buttonStyle(.plain)
                } else {
                    routeStops
                }

                routeDivider

                endpointSection(
                    title: "Финиш",
                    role: .finish,
                    selected: finishEndpointKind
                )
            }
        }
    }

    private var routeStops: some View {
        VStack(spacing: 0) {
            ForEach(Array(middleStops.enumerated()), id: \.element.element.id) { position, item in
                RouteTimelineStopRow(
                    pointNumber: item.offset,
                    stop: item.element,
                    isFirst: position == 0,
                    isLast: false,
                    canRemove: canRemoveStop(item.offset),
                    draggedStopID: $draggedStopID,
                    onEdit: {
                        onEditStop(item.element, item.offset)
                    },
                    onRemove: {
                        onRemoveStop(item.element)
                    }
                )
                .onDrop(
                    of: [UTType.text],
                    delegate: RouteStopDropDelegate(
                        targetID: item.element.id,
                        draggedStopID: $draggedStopID,
                        onMove: { draggedID in
                            onDropStop(draggedID, item.element.id)
                        }
                    )
                )

                if position < middleStops.count - 1 {
                    routeRowDivider
                }
            }

            RouteTimelineAddRow(onAddStop: onAddStop)
        }
    }

    private func endpointSection(
        title: String,
        role: RouteEndpointRole,
        selected: RouteEndpointKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture {
                    copyEndpointAddress(role)
                }
                .accessibilityHint("Удерживайте, чтобы скопировать адрес")
                .accessibilityAction(named: Text("Скопировать адрес")) {
                    copyEndpointAddress(role)
                }

            RouteEndpointPicker(
                selected: selected,
                isHomeAvailable: isHomeEndpointAvailable,
                onCopy: onCopyEndpoint,
                onSelect: { kind in
                    AppHaptics.trigger()
                    onEndpointSelect(role, kind)
                }
            )
        }
        .padding(.vertical, HomeLayout.routeEndpointSectionPadding)
    }

    private func copyEndpointAddress(_ role: RouteEndpointRole) {
        let address = role == .start ? stops.first?.address : stops.last?.address
        guard let address else { return }
        AppClipboard.copy(address, message: "Адрес скопирован")
    }

    private var routeDivider: some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(height: 1)
    }

    private var routeRowDivider: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.8))
            .frame(height: 1)
            .padding(.leading, HomeLayout.routeTimelineNodeWidth + HomeLayout.routeTimelineSpacing)
    }
}

private struct RouteTimelineStopRow: View {
    let pointNumber: Int
    let stop: RouteStop
    let isFirst: Bool
    let isLast: Bool
    let canRemove: Bool
    @Binding var draggedStopID: String?
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        rowContent
            .frame(maxWidth: .infinity, minHeight: HomeLayout.routeTimelineRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                AppHaptics.trigger()
                onEdit()
            }
            .contextMenu {
                Button {
                    AppHaptics.trigger()
                    onEdit()
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                }

                if canRemove {
                    Button(role: .destructive) {
                        AppHaptics.trigger()
                        onRemove()
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
            .opacity(draggedStopID == stop.id ? 0.72 : 1)
            .scaleEffect(draggedStopID == stop.id ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: draggedStopID)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Точка \(pointNumber), \(rowAccessibilityValue)")
            .accessibilityHint("Открывает редактор точки; долгое нажатие открывает действия")
            .accessibilityAction(named: "Редактировать") {
                onEdit()
            }
            .accessibilityAction(named: "Удалить") {
                if canRemove {
                    onRemove()
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: HomeLayout.routeTimelineSpacing) {
            RouteTimelineNode(
                title: String(pointNumber),
                isFirst: isFirst,
                isLast: isLast
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(stop.address.nilIfEmpty ?? "Адрес не указан")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stop.address.nilIfEmpty == nil ? AppTheme.mutedTint : AppTheme.ink)
                    .lineLimit(1)

                Text(stop.requestNumber.nilIfEmpty ?? "Номер заявки не указан")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stop.requestNumber.nilIfEmpty == nil ? AppTheme.mutedTint : AppTheme.primaryTint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RouteStopDragHandle()
                .onDrag {
                    draggedStopID = stop.id
                    AppHaptics.trigger(.expandCollapse)
                    return NSItemProvider(object: stop.id as NSString)
                } preview: {
                    RouteStopDragPreview(title: "Точка \(pointNumber)")
                }
        }
        .padding(.vertical, HomeLayout.routeTimelineRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowAccessibilityValue: String {
        [stop.address.nilIfEmpty, stop.requestNumber.nilIfEmpty]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct RouteTimelineNode: View {
    let title: String
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.primaryTint.opacity(isFirst ? 0 : 0.42))
                    .frame(width: 1)

                Rectangle()
                    .fill(AppTheme.primaryTint.opacity(isLast ? 0 : 0.42))
                    .frame(width: 1)
            }

            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: HomeLayout.routeTimelineNodeDiameter, height: HomeLayout.routeTimelineNodeDiameter)
                .background(AppTheme.accentGradient, in: Circle())
                .overlay(
                    Circle()
                        .stroke(AppTheme.primaryTint.opacity(0.42), lineWidth: 1)
                )
        }
        .frame(width: HomeLayout.routeTimelineNodeWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct RouteTimelineAddRow: View {
    let onAddStop: () -> Void

    var body: some View {
        HStack(spacing: HomeLayout.routeTimelineSpacing) {
            ZStack {
                Rectangle()
                    .fill(AppTheme.primaryTint.opacity(0.42))
                    .frame(width: 1)

                Button {
                    AppHaptics.trigger()
                    onAddStop()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppTheme.primaryTint)
                        .frame(width: HomeLayout.routeTimelineAddDiameter, height: HomeLayout.routeTimelineAddDiameter)
                        .background(AppTheme.buttonFill, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(AppTheme.primaryTint.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Добавить точку")
            }
            .frame(width: HomeLayout.routeTimelineNodeWidth)

            Text("Добавить точку")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryTint)

            Spacer()
        }
        .frame(height: HomeLayout.routeTimelineAddRowHeight)
    }
}

private struct RouteEndpointPicker: View {
    let selected: RouteEndpointKind
    let isHomeAvailable: Bool
    let onCopy: (RouteEndpointKind) -> Void
    let onSelect: (RouteEndpointKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RouteEndpointKind.allCases) { kind in
                RouteEndpointPickerButton(
                    kind: kind,
                    isSelected: selected == kind,
                    isDisabled: kind == .home && !isHomeAvailable,
                    onCopy: { onCopy(kind) }
                ) {
                    onSelect(kind)
                }
            }
        }
    }
}

private struct RouteEndpointPickerButton: View {
    let kind: RouteEndpointKind
    let isSelected: Bool
    let isDisabled: Bool
    let onCopy: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(kind.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .foregroundStyle(isSelected ? Color.white : AppTheme.ink)
            .frame(maxWidth: .infinity, minHeight: HomeLayout.routeEndpointHeight)
            .background(
                background,
                in: RoundedRectangle(
                    cornerRadius: HomeLayout.routeEndpointCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: HomeLayout.routeEndpointCornerRadius,
                    style: .continuous
                )
                .stroke(isSelected ? AppTheme.primaryTint.opacity(0.36) : AppTheme.border, lineWidth: 1)
            )
            .opacity(isDisabled ? 0.48 : 1)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onCopy() }
        )
        .disabled(isDisabled)
        .accessibilityLabel(kind.title)
        .accessibilityHint("Удерживайте, чтобы скопировать адрес")
        .accessibilityAction(named: Text("Скопировать адрес"), onCopy)
    }

    private var background: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(AppTheme.accentGradient)
        }
        return AnyShapeStyle(AppTheme.subpanelSurface)
    }
}

private struct RouteStopDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedStopID: String?
    let onMove: (String) -> Bool

    func dropEntered(info: DropInfo) {
        guard let draggedStopID,
              draggedStopID != targetID else {
            return
        }

        _ = onMove(draggedStopID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedStopID = nil
        return true
    }
}

private struct RouteStopDragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.mutedTint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Переместить точку")
    }
}

private struct RouteStopDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct RouteStopEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: RouteStopEditorSelection
    let officeAddresses: [String]
    let isLoadingOfficeAddresses: Bool
    let onRefreshOfficeAddresses: () async -> Void
    let onSave: (String, String) -> Void

    @State private var addressDraft: String
    @State private var requestNumberDraft: String
    @State private var isOfficePickerPresented = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address
        case requestNumber
    }

    init(
        selection: RouteStopEditorSelection,
        officeAddresses: [String] = [],
        isLoadingOfficeAddresses: Bool = false,
        onRefreshOfficeAddresses: @escaping () async -> Void = {},
        onSave: @escaping (String, String) -> Void
    ) {
        self.selection = selection
        self.officeAddresses = officeAddresses
        self.isLoadingOfficeAddresses = isLoadingOfficeAddresses
        self.onRefreshOfficeAddresses = onRefreshOfficeAddresses
        self.onSave = onSave
        _addressDraft = State(initialValue: selection.stop.address)
        _requestNumberDraft = State(initialValue: selection.stop.requestNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Точка \(selection.pointNumber)")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .center)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    editorField(title: "Адрес") {
                        if selection.requiresOfficeSelection {
                            Button {
                                AppHaptics.trigger()
                                isOfficePickerPresented = true
                            } label: {
                                HStack(spacing: 8) {
                                    Text(addressDraft.nilIfEmpty ?? "Выбрать отделение")
                                        .foregroundStyle(addressDraft.nilIfEmpty == nil ? AppTheme.mutedTint : AppTheme.ink)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if isLoadingOfficeAddresses {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(AppTheme.mutedTint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            TextField("Адрес", text: $addressDraft)
                                .textContentType(.fullStreetAddress)
                                .focused($focusedField, equals: .address)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .requestNumber }
                        }
                    }

                    editorField(title: "Номер заявки") {
                        TextField("Номер заявки", text: $requestNumberDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .requestNumber)
                            .submitLabel(.done)
                            .onSubmit { save() }
                    }
                }
            }

            if !selection.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selection.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                AppHaptics.trigger()
                                addressDraft = suggestion
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryTint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(AppTheme.primaryTint.opacity(0.12), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Отмена")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)

                Button(action: save) {
                    Text("Сохранить")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(AppTheme.primaryTint)
                .disabled(selection.requiresOfficeSelection && addressDraft.nilIfEmpty == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .sheet(isPresented: $isOfficePickerPresented) {
            NavigationStack {
                RouteOfficeAddressPicker(
                    addresses: officeAddresses,
                    isLoading: isLoadingOfficeAddresses,
                    onRefresh: onRefreshOfficeAddresses,
                    onSelect: { address in
                        addressDraft = address
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func editorField<FieldContent: View>(
        title: String,
        @ViewBuilder content: () -> FieldContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedTint)

            content()
                .font(.body)
                .foregroundStyle(AppTheme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private func save() {
        AppHaptics.trigger()
        onSave(addressDraft, requestNumberDraft)
        dismiss()
    }
}

private struct RouteOfficeAddressPicker: View {
    @Environment(\.dismiss) private var dismiss

    let addresses: [String]
    let isLoading: Bool
    let onRefresh: () async -> Void
    let onSelect: (String) -> Void

    @State private var query = ""

    var body: some View {
        Group {
            if addresses.isEmpty {
                ContentUnavailableView {
                    Label("Отделения не загружены", systemImage: "building.2")
                } description: {
                    Text("Проверьте город работы в профиле и обновите список.")
                } actions: {
                    Button("Обновить") {
                        Task { await onRefresh() }
                    }
                    .disabled(isLoading)
                }
            } else {
                List(filteredAddresses, id: \.self) { address in
                    Button {
                        AppHaptics.trigger()
                        onSelect(address)
                        dismiss()
                    } label: {
                        Label(address, systemImage: "building.2")
                            .foregroundStyle(AppTheme.ink)
                    }
                }
                .listStyle(.plain)
            }
        }
        .overlay {
            if isLoading, addresses.isEmpty {
                ProgressView("Загружаем отделения…")
            }
        }
        .navigationTitle("Адрес отделения")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Город, улица или дом")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ModalCloseButton(action: dismiss.callAsFunction)
            }
        }
        .task {
            if addresses.isEmpty {
                await onRefresh()
            }
        }
    }

    private var filteredAddresses: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return addresses }
        return addresses.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
