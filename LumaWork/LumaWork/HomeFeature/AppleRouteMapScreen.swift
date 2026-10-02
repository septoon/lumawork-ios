import MapKit
import SwiftUI

struct AppleRouteMapDestination: Identifiable {
    let id = UUID()
    let snapshot: AppleRouteDistanceSnapshot
}

struct AppleRouteMapScreen: View {
    let snapshot: AppleRouteDistanceSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition

    init(snapshot: AppleRouteDistanceSnapshot) {
        self.snapshot = snapshot
        _camera = State(initialValue: .rect(Self.mapRect(for: snapshot)))
    }

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                ForEach(Array((snapshot.legs ?? []).enumerated()), id: \.offset) { _, leg in
                    MapPolyline(coordinates: leg.coordinates.map(\.coordinate))
                        .stroke(.blue, lineWidth: 5)
                }

                ForEach(stops) { stop in
                    Annotation(stop.title, coordinate: stop.coordinate.coordinate) {
                        Text(stop.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(stop.isEndpoint ? Color.green : Color.blue, in: Capsule())
                            .overlay(Capsule().stroke(.white, lineWidth: 2))
                            .accessibilityLabel(stop.title)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("Пробег через Apple Maps: \(snapshot.distanceKm) км")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 8)
                    Button("Показать весь маршрут", systemImage: "arrow.up.left.and.arrow.down.right") {
                        camera = .rect(Self.mapRect(for: snapshot))
                    }
                    .labelStyle(.iconOnly)
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Маршрут Apple Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ModalCloseButton(action: dismiss.callAsFunction)
                }
            }
        }
    }

    private struct Stop: Identifiable {
        let id: Int
        let coordinate: AppleRouteCoordinate
        var label: String
        var title: String
        var isEndpoint: Bool
    }

    private var stops: [Stop] {
        var result: [Stop] = []
        for (index, coordinate) in (snapshot.stopCoordinates ?? []).enumerated() {
            let isStart = index == 0
            let isFinish = index == snapshot.addresses.count - 1
            let label = isStart ? "С" : isFinish ? "Ф" : "\(index)"
            let role = isStart ? "Старт" : isFinish ? "Финиш" : "Точка \(index)"
            let title = "\(role): \(snapshot.addresses[index])"
            if let existingIndex = result.firstIndex(where: { $0.coordinate == coordinate }) {
                result[existingIndex].label += "/\(label)"
                result[existingIndex].title += " · \(title)"
                result[existingIndex].isEndpoint = result[existingIndex].isEndpoint || isFinish
            } else {
                result.append(Stop(id: index, coordinate: coordinate, label: label, title: title, isEndpoint: isStart || isFinish))
            }
        }
        return result
    }

    private static func mapRect(for snapshot: AppleRouteDistanceSnapshot) -> MKMapRect {
        let coordinates = (snapshot.stopCoordinates ?? []) + (snapshot.legs ?? []).flatMap(\.coordinates)
        let points = coordinates.map { MKMapPoint($0.coordinate) }
        guard let first = points.first else { return .world }
        let minX = points.map(\.x).min() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxX = points.map(\.x).max() ?? first.x
        let maxY = points.map(\.y).max() ?? first.y
        let width = max(maxX - minX, 2_000)
        let height = max(maxY - minY, 2_000)
        return MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
            .insetBy(dx: -width * 0.15, dy: -height * 0.15)
    }
}
