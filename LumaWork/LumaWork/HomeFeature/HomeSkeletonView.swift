import SwiftUI

struct HomeSkeletonView: View {
    var body: some View {
        AppScreen(bottomContentPadding: HomeLayout.bottomContentPadding) {
            activeRequestsCard
            dayControlsCard
            routeEndpointCard
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SkeletonPlaceholder(cornerRadius: 6)
                    .frame(width: 72, height: 16)
            }

            ToolbarItem(placement: .topBarTrailing) {
                SkeletonPlaceholder(cornerRadius: 22)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Загружается профиль")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .safeAreaBar(edge: .bottom) {
            SkeletonPlaceholder(cornerRadius: 21)
                .frame(maxWidth: .infinity)
                .frame(height: HomeLayout.sendButtonMinHeight)
                .padding(.horizontal, HomeLayout.bottomBarHorizontalPadding)
                .padding(.vertical, HomeLayout.bottomBarVerticalPadding)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружается главная")
    }

    private var activeRequestsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: HomeLayout.activeRequestsContentSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonPlaceholder(cornerRadius: 7)
                        .frame(width: 154, height: HomeLayout.skeletonHeaderTitleHeight)
                    SkeletonPlaceholder(cornerRadius: 6)
                        .frame(width: 104, height: HomeLayout.skeletonHeaderCaptionHeight)
                }

                HStack(spacing: HomeLayout.metricSpacing) {
                    ForEach(0..<3, id: \.self) { index in
                        HomeMetricContainer(
                            tint: Color("AppSkeletonSurface"),
                            backgroundOpacity: 1
                        ) {
                            VStack(alignment: .leading, spacing: HomeLayout.metricContentSpacing) {
                                SkeletonPlaceholder(cornerRadius: 4)
                                    .frame(width: index == 1 ? 52 : 42, height: 12)
                                SkeletonPlaceholder(cornerRadius: 6)
                                    .frame(width: 24, height: 23)
                            }
                        }
                    }
                }

                HomeRequestSummaryContainer(
                    tint: Color("AppSkeletonSurface"),
                    backgroundOpacity: 1,
                    borderOpacity: 1
                ) {
                    VStack(alignment: .leading, spacing: HomeLayout.requestSummarySpacing) {
                        HStack(spacing: 8) {
                            SkeletonPlaceholder(cornerRadius: 5)
                                .frame(width: 92, height: 19)
                            Spacer(minLength: 8)
                            SkeletonPlaceholder(cornerRadius: 8)
                                .frame(width: 66, height: 19)
                        }
                        SkeletonPlaceholder(cornerRadius: 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 14)
                        SkeletonPlaceholder(cornerRadius: 4)
                            .frame(width: 132, height: 14)
                        HStack(spacing: 12) {
                            SkeletonPlaceholder(cornerRadius: 4)
                                .frame(maxWidth: .infinity)
                                .frame(height: 14)
                            SkeletonPlaceholder(cornerRadius: 4)
                                .frame(maxWidth: .infinity)
                                .frame(height: 14)
                        }
                    }
                }
                .frame(height: HomeLayout.skeletonRequestSummaryHeight)
            }
        }
    }

    private var dayControlsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: HomeLayout.dayContentSpacing) {
                HStack(alignment: .center, spacing: HomeLayout.dayHeaderSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        SkeletonPlaceholder(cornerRadius: 4)
                            .frame(width: 86, height: 15)
                        SkeletonPlaceholder(cornerRadius: 6)
                            .frame(width: 146, height: 28)
                    }
                    .frame(height: HomeLayout.skeletonDayHeaderHeight, alignment: .leading)

                    Spacer(minLength: 0)

                    SkeletonPlaceholder(cornerRadius: 17)
                        .frame(width: 150, height: 34)
                }

                skeletonDivider

                HStack(spacing: HomeLayout.mileageSpacing) {
                    SkeletonPlaceholder(cornerRadius: 5)
                        .frame(width: 102, height: 19)
                    Spacer(minLength: 4)
                    SkeletonPlaceholder(cornerRadius: HomeLayout.mileageFieldCornerRadius)
                        .frame(
                            width: HomeLayout.mileageFieldWidth,
                            height: HomeLayout.mileageFieldHeight
                        )
                    SkeletonPlaceholder(cornerRadius: 4)
                        .frame(width: 20, height: 19)
                    SkeletonPlaceholder(cornerRadius: 17)
                        .frame(width: 34, height: 34)
                }
                .frame(height: HomeLayout.mileageFieldHeight)

                skeletonDivider

                SkeletonPlaceholder(cornerRadius: 5)
                    .frame(width: 230, height: 19)

                skeletonDivider

                HStack(spacing: HomeLayout.odometerSpacing) {
                    SkeletonPlaceholder(cornerRadius: 17)
                        .frame(width: 34, height: 34)
                    SkeletonPlaceholder(cornerRadius: 5)
                        .frame(width: 132, height: 19)
                    Spacer(minLength: 8)
                    SkeletonPlaceholder(cornerRadius: 4)
                        .frame(width: 8, height: 14)
                }
                .frame(minHeight: HomeLayout.odometerMinHeight)
            }
        }
    }

    private var routeEndpointCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SkeletonPlaceholder(cornerRadius: 5)
                        .frame(width: 62, height: HomeLayout.skeletonRouteHeaderHeight)
                    Spacer()
                }

                HStack(spacing: 8) {
                    SkeletonPlaceholder(cornerRadius: HomeLayout.routeEndpointCornerRadius)
                        .frame(maxWidth: .infinity)
                        .frame(height: HomeLayout.routeEndpointHeight)
                    SkeletonPlaceholder(cornerRadius: HomeLayout.routeEndpointCornerRadius)
                        .frame(maxWidth: .infinity)
                        .frame(height: HomeLayout.routeEndpointHeight)
                }
            }
        }
    }

    private var skeletonDivider: some View {
        Rectangle()
            .fill(Color("AppBorder"))
            .frame(height: 1)
    }
}

struct SkeletonPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color("AppSkeletonBase"))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                .clear,
                                Color("AppSkeletonHighlight"),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(
                            width: max(proxy.size.width * 0.72, 28),
                            height: proxy.size.height
                        )
                        .offset(x: shimmerPhase * (proxy.size.width * 1.8))
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                }
            }
            .task(id: reduceMotion) {
                shimmerPhase = -1
                guard !reduceMotion else { return }
                await Task.yield()
                withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack {
        HomeSkeletonView()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppSidebarMenuButton {}
                }
            }
    }
}
