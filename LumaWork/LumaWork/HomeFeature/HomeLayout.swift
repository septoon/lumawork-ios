import SwiftUI

enum HomeLayout {
    static let bottomContentPadding: CGFloat = 12
    static let activeRequestsContentSpacing: CGFloat = 10
    static let metricSpacing: CGFloat = 7
    static let metricContentSpacing: CGFloat = 5
    static let metricHorizontalPadding: CGFloat = 9
    static let metricVerticalPadding: CGFloat = 8
    static let metricMinHeight: CGFloat = 58
    static let metricCornerRadius: CGFloat = 13
    static let requestSummarySpacing: CGFloat = 7
    static let requestSummaryPadding: CGFloat = 11
    static let requestSummaryCornerRadius: CGFloat = 15
    static let dayContentSpacing: CGFloat = 14
    static let dayHeaderSpacing: CGFloat = 12
    static let mileageSpacing: CGFloat = 9
    static let mileageFieldWidth: CGFloat = 82
    static let mileageFieldHeight: CGFloat = 42
    static let mileageFieldCornerRadius: CGFloat = 12
    static let odometerSpacing: CGFloat = 10
    static let odometerMinHeight: CGFloat = 38
    static let routeEndpointHeight: CGFloat = 46
    static let routeEndpointCornerRadius: CGFloat = 15
    static let routeEndpointSectionPadding: CGFloat = 14
    static let routeEmptyHeight: CGFloat = 64
    static let routeTimelineRowHeight: CGFloat = 72
    static let routeTimelineRowVerticalPadding: CGFloat = 8
    static let routeTimelineSpacing: CGFloat = 12
    static let routeTimelineNodeWidth: CGFloat = 44
    static let routeTimelineNodeDiameter: CGFloat = 40
    static let routeTimelineAddDiameter: CGFloat = 34
    static let routeTimelineAddRowHeight: CGFloat = 46
    static let bottomBarHorizontalPadding: CGFloat = 20
    static let bottomBarVerticalPadding: CGFloat = 20
    static let sendButtonMinHeight: CGFloat = 42

    static let skeletonHeaderTitleHeight: CGFloat = 23
    static let skeletonHeaderCaptionHeight: CGFloat = 19
    static let skeletonRequestSummaryHeight: CGFloat = 104
    static let skeletonDayHeaderHeight: CGFloat = 47
    static let skeletonRouteHeaderHeight: CGFloat = 20
}

struct HomeMetricContainer<Content: View>: View {
    let tint: Color
    let backgroundOpacity: Double
    let content: Content

    init(
        tint: Color,
        backgroundOpacity: Double = 0.08,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, HomeLayout.metricHorizontalPadding)
            .padding(.vertical, HomeLayout.metricVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: HomeLayout.metricMinHeight, alignment: .leading)
            .background(
                tint.opacity(backgroundOpacity),
                in: RoundedRectangle(
                    cornerRadius: HomeLayout.metricCornerRadius,
                    style: .continuous
                )
            )
    }
}

struct HomeRequestSummaryContainer<Content: View>: View {
    let tint: Color
    let backgroundOpacity: Double
    let borderOpacity: Double
    let content: Content

    init(
        tint: Color,
        backgroundOpacity: Double = 0.055,
        borderOpacity: Double = 0.12,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.backgroundOpacity = backgroundOpacity
        self.borderOpacity = borderOpacity
        self.content = content()
    }

    var body: some View {
        content
            .padding(HomeLayout.requestSummaryPadding)
            .background(
                tint.opacity(backgroundOpacity),
                in: RoundedRectangle(
                    cornerRadius: HomeLayout.requestSummaryCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: HomeLayout.requestSummaryCornerRadius,
                    style: .continuous
                )
                .stroke(tint.opacity(borderOpacity), lineWidth: 1)
            )
    }
}
