import SwiftUI
import UIKit

enum AppHapticStyle {
    case tap
    case expandCollapse
    case carouselSelection
    case download
    case refreshThreshold
    case success
    case error
}

enum AppHaptics {
    static func trigger(_ style: AppHapticStyle = .tap) {
        switch style {
        case .tap:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred(intensity: 0.9)
        case .expandCollapse:
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        case .carouselSelection:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred(intensity: 1)
        case .download:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred(intensity: 0.85)
        case .refreshThreshold:
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred(intensity: 0.9)
        case .success:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .error:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        }
    }
}

extension View {
    func appTapHaptic(_ style: AppHapticStyle = .tap) -> some View {
        self
    }
}

private final class KeyboardDismissTapGestureRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var currentView = touch.view

        while let view = currentView {
            if view is UITextField || view is UITextView {
                return false
            }
            currentView = view.superview
        }

        return true
    }
}

private final class KeyboardDismissInstallerView: UIView {
    @objc
    private func handleWindowTap() {
        window?.endEditing(true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard let window else { return }
        let alreadyInstalled = window.gestureRecognizers?.contains(where: { $0 is KeyboardDismissTapGestureRecognizer }) ?? false
        guard !alreadyInstalled else { return }

        let recognizer = KeyboardDismissTapGestureRecognizer(
            target: self,
            action: #selector(handleWindowTap)
        )
        window.addGestureRecognizer(recognizer)
    }
}

struct KeyboardDismissOnTapInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        KeyboardDismissInstallerView(frame: .zero)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
