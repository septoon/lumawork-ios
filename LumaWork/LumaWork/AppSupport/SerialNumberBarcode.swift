import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

nonisolated struct SerialNumberBarcodeSelection: Identifiable {
    let serialNumber: String
    var id: String { serialNumber }

    init?(_ value: String) {
        let serialNumber = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = [
            "", "-", "—", "(не задано)", "не задано", "не указан", "не указано", "информация отсутствует"
        ]
        guard !placeholders.contains(serialNumber.lowercased()) else { return nil }
        self.serialNumber = serialNumber
    }

    static func isSerialNumberField(_ title: String?) -> Bool {
        let normalized = (title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "cерийный", with: "серийный")
        return normalized.hasPrefix("s/n") || normalized.hasPrefix("серийный номер")
    }
}

enum SerialNumberBarcodeBuilder {
    private static let context = CIContext()

    static func image(for serialNumber: String) -> CGImage? {
        guard !serialNumber.isEmpty,
              let message = serialNumber.data(using: .ascii, allowLossyConversion: false) else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = message
        filter.quietSpace = 12
        filter.barcodeHeight = 64
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

#if canImport(UIKit)
import SwiftUI

private struct SerialNumberBarcodeModifier: ViewModifier {
    let value: String
    let isEnabled: Bool
    @State private var selection: SerialNumberBarcodeSelection?

    func body(content: Content) -> some View {
        if isEnabled, let serialNumber = SerialNumberBarcodeSelection(value) {
            Button {
                AppHaptics.trigger()
                selection = serialNumber
            } label: {
                content
                    .allowsHitTesting(false)
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Серийный номер: \(serialNumber.serialNumber)")
            .accessibilityHint("Открывает штрихкод серийного номера")
            .sheet(item: $selection) { selection in
                SerialNumberBarcodeSheet(selection: selection)
            }
        } else {
            content
        }
    }
}

extension View {
    func serialNumberBarcode(value: String, isEnabled: Bool = true) -> some View {
        modifier(SerialNumberBarcodeModifier(value: value, isEnabled: isEnabled))
    }
}

private struct SerialNumberBarcodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: SerialNumberBarcodeSelection
    private let barcode: CGImage?

    init(selection: SerialNumberBarcodeSelection) {
        self.selection = selection
        self.barcode = SerialNumberBarcodeBuilder.image(for: selection.serialNumber)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let barcode {
                        Image(decorative: barcode, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .frame(height: 140)
                            .accessibilityHidden(true)
                    } else {
                        Text("Не удалось создать штрихкод для этого серийного номера")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }

                    Text(selection.serialNumber)
                        .font(.title3.monospaced().weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.black)
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .padding(16)
            }
            .background(AppTheme.background)
            .navigationTitle("Штрихкод S/N")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.height(340), .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
