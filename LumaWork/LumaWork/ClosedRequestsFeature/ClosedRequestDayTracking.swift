import SwiftUI

struct ClosedRequestDayPositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ClosedRequestDayMarker: View {
    let dayKey: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ClosedRequestDayPositionKey.self,
                value: [dayKey: geometry.frame(in: .scrollView(axis: .vertical)).minY]
            )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

enum ClosedRequestDayTracking {
    static func visibleKey(
        orderedKeys: [String],
        positions: [String: CGFloat],
        pinY: CGFloat = 12
    ) -> String? {
        guard let first = orderedKeys.first else { return nil }
        return orderedKeys.last { key in
            guard let position = positions[key] else { return false }
            return position <= pinY
        } ?? first
    }
}
