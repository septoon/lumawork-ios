import MapKit
import SwiftUI

struct AppleRouteMapDestination: Identifiable {
    let id = UUID()
    let snapshot: AppleRouteDistanceSnapshot
}

struct AppleRouteMapScreen: View {
    let routeStore: HomeRouteStore
    @Environment(\.dismiss) private var dismiss
    @State private var original: RouteDayRecord
    @State private var snapshot: AppleRouteDistanceSnapshot
    @State private var coordinates: [AppleRouteCoordinate]
    @State private var overrides: [AppleRouteCoordinate?]
    @State private var remembered: Set<Int> = []
    @State private var forgotten: Set<Int> = []
    @State private var selectedIndex = 0
    @State private var isEditing = false
    @State private var fitRevision = 0

    init(snapshot: AppleRouteDistanceSnapshot, routeStore: HomeRouteStore) {
        self.routeStore = routeStore
        _original = State(initialValue: routeStore.record)
        _snapshot = State(initialValue: snapshot)
        _coordinates = State(initialValue: snapshot.stopCoordinates ?? [])
        _overrides = State(initialValue: routeStore.currentAppleRoutePlan.coordinateOverrides)
    }

    private var hasChanges: Bool {
        overrides != routeStore.currentAppleRoutePlan.coordinateOverrides || !remembered.isEmpty || !forgotten.isEmpty
    }

    private var isCurrentDay: Bool {
        original.date == routeStore.record.date && original.workType == routeStore.record.workType
    }

    private var canEdit: Bool {
        isCurrentDay && snapshot.addresses == routeStore.currentAppleRoutePlan.addresses
            && !routeStore.isCalculatingAppleDistance && !routeStore.isSending
    }

    var body: some View {
        NavigationStack {
            EditableAppleRouteMap(
                addresses: snapshot.addresses, coordinates: coordinates,
                legs: isEditing || routeStore.isCalculatingAppleDistance || routeStore.appleDistanceError != nil ? [] : snapshot.legs ?? [],
                unverified: Set(snapshot.unverifiedStopIndices ?? []),
                selectedIndex: selectedIndex, isEditing: isEditing, fitRevision: fitRevision,
                onSelect: { selectedIndex = $0 },
                onMove: { index, coordinate in
                    guard coordinates.indices.contains(index), overrides.indices.contains(index), coordinate.isValid else { return }
                    coordinates[index] = coordinate
                    overrides[index] = coordinate
                    forgotten.remove(index)
                    selectedIndex = index
                }
            )
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Маршрут")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isEditing {
                        ModalCloseButton(action: cancelEditing)
                    } else {
                        Button("Изменить точки", systemImage: "pencil") { beginEditing() }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                            .disabled(!canEdit)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        ModalConfirmButton(
                            action: apply,
                            isDisabled: !hasChanges || !canEdit,
                            accessibilityLabel: "Применить"
                        )
                    } else {
                        ModalCloseButton(action: dismiss.callAsFunction)
                    }
                }
            }
            .interactiveDismissDisabled(isEditing)
            .onChange(of: routeStore.appleRouteSnapshot?.stopCoordinates) { _, _ in
                guard !isEditing, isCurrentDay, let updated = routeStore.appleRouteSnapshot, updated.hasGeometry else { return }
                snapshot = updated
                coordinates = updated.stopCoordinates ?? []
                overrides = routeStore.currentAppleRoutePlan.coordinateOverrides
                original = routeStore.record
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                Text("Удерживайте метку и перемещайте её пальцем.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Точка", selection: $selectedIndex) {
                    ForEach(snapshot.addresses.indices, id: \.self) { index in
                        Text("\(label(index)): \(snapshot.addresses[index])").tag(index)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.primaryTint)
                if overrides.indices.contains(selectedIndex) {
                    Toggle("Запомнить для этого адреса", isOn: Binding(
                        get: { remembered.contains(selectedIndex) },
                        set: { value in
                            if value {
                                remembered.insert(selectedIndex)
                                forgotten.remove(selectedIndex)
                                overrides[selectedIndex] = coordinates[selectedIndex]
                            } else { remembered.remove(selectedIndex) }
                        }
                    ))
                    .font(.subheadline)
                    HStack {
                        Button("Подтвердить точку") {
                            overrides[selectedIndex] = coordinates[selectedIndex]
                            forgotten.remove(selectedIndex)
                        }
                        .disabled(overrides[selectedIndex] != nil)
                        Spacer(minLength: 8)
                        Button("Сбросить исправление") {
                            overrides[selectedIndex] = nil
                            remembered.remove(selectedIndex)
                            forgotten.insert(selectedIndex)
                        }
                        .disabled(overrides[selectedIndex] == nil && !remembered.contains(selectedIndex))
                    }
                    .font(.caption.weight(.semibold))
                }
                Text(hasChanges ? "После применения маршрут и пробег будут пересчитаны." : "Выберите точку на карте или в списке.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(routeStore.isCalculatingAppleDistance ? "Пересчитываем маршрут…" : mileageText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .overlay {
                            if routeStore.isCalculatingAppleDistance {
                                SkeletonPlaceholder().mask(Text("Пересчитываем маршрут…"))
                            }
                        }
                    Spacer(minLength: 8)
                    Button("Показать весь маршрут", systemImage: "arrow.up.left.and.arrow.down.right") { fitRevision += 1 }
                        .labelStyle(.iconOnly)
                }
                if let error = routeStore.appleDistanceError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Повторить расчёт") { routeStore.refreshAppleDistance(force: true) }
                        .font(.caption.weight(.semibold))
                } else if !routeStore.isCalculatingAppleDistance, snapshot.unverifiedStopIndices?.isEmpty == false {
                    Text("Проверьте оранжевые точки. Пробег можно отправить после подтверждения расположения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var mileageText: String {
        guard isCurrentDay, let distance = routeStore.appleDistanceKm else { return "Пробег через Apple Maps: —" }
        return "Пробег через Apple Maps: \(distance) км"
    }

    private func label(_ index: Int) -> String {
        index == 0 ? "Старт" : index == snapshot.addresses.count - 1 ? "Финиш" : "Точка \(index)"
    }

    private func beginEditing() {
        original = routeStore.record
        overrides = routeStore.currentAppleRoutePlan.coordinateOverrides
        remembered = []
        forgotten = []
        selectedIndex = snapshot.unverifiedStopIndices?.first ?? min(1, coordinates.count - 1)
        isEditing = true
    }

    private func cancelEditing() {
        coordinates = snapshot.stopCoordinates ?? []
        overrides = routeStore.currentAppleRoutePlan.coordinateOverrides
        remembered = []
        forgotten = []
        isEditing = false
    }

    private func apply() {
        guard routeStore.applyRouteCoordinates(from: original, overrides: overrides, remember: remembered, forget: forgotten) else {
            AppErrorPresentation.presentIfNeeded(message: "Маршрут изменился. Закройте карту и откройте её заново.")
            return
        }
        original = routeStore.record
        remembered = []
        forgotten = []
        isEditing = false
    }
}

// Native annotation dragging keeps map panning and point dragging distinct.
private struct EditableAppleRouteMap: UIViewRepresentable {
    let addresses: [String]
    let coordinates: [AppleRouteCoordinate]
    let legs: [AppleRouteLeg]
    let unverified: Set<Int>
    let selectedIndex: Int
    let isEditing: Bool
    let fitRevision: Int
    let onSelect: (Int) -> Void
    let onMove: (Int, AppleRouteCoordinate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "route-stop")
        map.showsCompass = true
        map.showsScale = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.annotations.count != coordinates.count {
            map.removeAnnotations(coordinator.annotations)
            coordinator.annotations = coordinates.enumerated().map { index, coordinate in
                let annotation = StopAnnotation()
                annotation.index = index
                annotation.coordinate = coordinate.coordinate
                return annotation
            }
            map.addAnnotations(coordinator.annotations)
        }
        for annotation in coordinator.annotations {
            let index = annotation.index
            guard addresses.indices.contains(index), coordinates.indices.contains(index) else { continue }
            annotation.title = addresses[index]
            annotation.subtitle = unverified.contains(index) ? "Проверьте расположение" : nil
            if let view = map.view(for: annotation) as? MKMarkerAnnotationView {
                coordinator.configure(view, annotation: annotation)
                if view.dragState == .none { annotation.coordinate = coordinates[index].coordinate }
            } else { annotation.coordinate = coordinates[index].coordinate }
        }
        let geometry = legs.flatMap(\.coordinates)
        if coordinator.geometry != geometry {
            map.removeOverlays(map.overlays)
            for leg in legs where leg.coordinates.count > 1 {
                var points = leg.coordinates.map(\.coordinate)
                map.addOverlay(MKPolyline(coordinates: &points, count: points.count))
            }
            coordinator.geometry = geometry
        }
        if isEditing, coordinator.lastSelection != selectedIndex, coordinator.annotations.indices.contains(selectedIndex) {
            let annotation = coordinator.annotations[selectedIndex]
            map.selectAnnotation(annotation, animated: true)
            map.setCenter(annotation.coordinate, animated: true)
        }
        coordinator.lastSelection = selectedIndex
        if coordinator.fitRevision != fitRevision {
            let points = (coordinates + geometry).map { MKMapPoint($0.coordinate) }
            if let first = points.first {
                var rect = MKMapRect(x: first.x, y: first.y, width: 0, height: 0)
                for point in points { rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1)) }
                let width = max(rect.width, 2_000)
                let height = max(rect.height, 2_000)
                rect = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
                let animated = coordinator.fitRevision != nil
                DispatchQueue.main.async {
                    map.layoutIfNeeded()
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 40, bottom: 70, right: 40), animated: animated)
                }
            }
            coordinator.fitRevision = fitRevision
        }
    }

    fileprivate final class StopAnnotation: MKPointAnnotation {
        var index = 0
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EditableAppleRouteMap
        fileprivate var annotations: [StopAnnotation] = []
        var geometry: [AppleRouteCoordinate] = []
        var fitRevision: Int?
        var lastSelection: Int?
        init(_ parent: EditableAppleRouteMap) { self.parent = parent }

        fileprivate func configure(_ view: MKMarkerAnnotationView, annotation: StopAnnotation) {
            let index = annotation.index
            view.isDraggable = parent.isEditing
            view.canShowCallout = !parent.isEditing
            view.markerTintColor = parent.unverified.contains(index) ? .systemOrange : index == 0 || index == parent.addresses.count - 1 ? .systemGreen : .systemBlue
            view.glyphText = index == 0 ? "С" : index == parent.addresses.count - 1 ? "Ф" : "\(index)"
            view.displayPriority = .required
            view.accessibilityLabel = "\(view.glyphText ?? ""): \(annotation.title ?? "")"
            view.accessibilityHint = parent.isEditing ? "Удерживайте и перемещайте точку" : ""
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? StopAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "route-stop", for: annotation) as! MKMarkerAnnotationView
            configure(view, annotation: annotation)
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? StopAnnotation else { return }
            lastSelection = annotation.index
            DispatchQueue.main.async { self.parent.onSelect(annotation.index) }
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard let annotation = view.annotation as? StopAnnotation else { return }
            if newState == .ending {
                let coordinate = AppleRouteCoordinate(annotation.coordinate)
                parent.onMove(annotation.index, coordinate)
                view.setDragState(.none, animated: true)
            } else if newState == .canceling { view.setDragState(.none, animated: true) }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
            return renderer
        }
    }
}
