import SwiftUI

nonisolated struct DepthStackEffectValues {
    let progress: CGFloat
    let pinnedOffset: CGFloat
    let scale: CGFloat
    let blurRadius: CGFloat
    let opacity: CGFloat
}

nonisolated enum DepthStackEffect {
    static func layer(forStage stage: Int) -> Double {
        Double(max(stage, 0))
    }

    static func values(
        cardMinY: CGFloat,
        pinY: CGFloat,
        cardHeight: CGFloat,
        reduceMotion: Bool
    ) -> DepthStackEffectValues {
        guard !reduceMotion else {
            return DepthStackEffectValues(
                progress: 0,
                pinnedOffset: 0,
                scale: 1,
                blurRadius: 0,
                opacity: 1
            )
        }

        let pinnedOffset = max(pinY - cardMinY, 0)
        let progress = min(pinnedOffset / max(cardHeight, 1), 1)

        return DepthStackEffectValues(
            progress: progress,
            pinnedOffset: pinnedOffset,
            scale: 1 - progress * 0.06,
            blurRadius: progress * 12,
            opacity: 1 - progress * 0.08
        )
    }
}

private struct DepthStackPrimaryModifier: ViewModifier {
    let reduceMotion: Bool
    let pinY: CGFloat
    let stage: Int

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, geometry in
                let frame = geometry.frame(in: .scrollView(axis: .vertical))
                let values = DepthStackEffect.values(
                    cardMinY: frame.minY,
                    pinY: pinY,
                    cardHeight: frame.height,
                    reduceMotion: reduceMotion
                )

                return effect
                    .scaleEffect(values.scale, anchor: .top)
                    .blur(radius: values.blurRadius)
                    .opacity(values.opacity)
                    .offset(y: values.pinnedOffset)
            }
            .zIndex(DepthStackEffect.layer(forStage: stage))
    }
}

extension View {
    func depthStackPrimary(
        reduceMotion: Bool,
        pinY: CGFloat = 12,
        stage: Int = 0
    ) -> some View {
        modifier(
            DepthStackPrimaryModifier(
                reduceMotion: reduceMotion,
                pinY: pinY,
                stage: stage
            )
        )
    }

    func depthStackSecondary(stage: Int = 1) -> some View {
        zIndex(DepthStackEffect.layer(forStage: stage))
    }
}
