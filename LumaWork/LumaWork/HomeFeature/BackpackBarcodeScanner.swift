import Foundation
import Vision

nonisolated enum BackpackBarcodeReader {
    static let symbologies: [VNBarcodeSymbology] = [
        .code128, .code39, .code93, .ean13, .ean8, .upce, .itf14, .i2of5
    ]

    static func serialNumber(in data: Data) throws -> String? {
        let request = VNDetectBarcodesRequest()
        #if targetEnvironment(simulator)
        // Legacy revision 1 works without the latest detector's unavailable simulator inference context.
        request.revision = 1
        #endif
        request.symbologies = symbologies
        try VNImageRequestHandler(data: data).perform([request])
        return request.results?.compactMap { result in
            result.payloadStringValue.flatMap { SerialNumberBarcodeSelection($0)?.serialNumber }
        }.first
    }
}

#if canImport(UIKit)
import AVFoundation
import PhotosUI
import SwiftUI
import VisionKit

struct BackpackBarcodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAuthorized = false
    @State private var isCheckingCamera = true
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isReadingPhoto = false
    @State private var errorMessage: String?
    @State private var hasAcceptedCode = false
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isCheckingCamera {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cameraAuthorized && DataScannerViewController.isAvailable {
                    BackpackLiveBarcodeScanner(
                        isScanning: scenePhase == .active && !isReadingPhoto && !hasAcceptedCode,
                        onScan: accept,
                        onError: { errorMessage = $0 }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .bottom) {
                        Text("Наведите камеру на штрихкод серийного номера")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(12)
                    }
                } else {
                    ContentUnavailableView(
                        "Камера недоступна",
                        systemImage: "barcode.viewfinder",
                        description: Text(DataScannerViewController.isSupported
                            ? "Разрешите доступ к камере в настройках или выберите фото штрихкода."
                            : "На этом устройстве можно считать штрихкод с фотографии.")
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.dangerTint)
                        .multilineTextAlignment(.center)
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(isReadingPhoto ? "Считываю штрихкод…" : "Выбрать фото штрихкода", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isReadingPhoto)
            }
            .padding(16)
            .background(AppTheme.background)
            .navigationTitle("Сканировать S/N")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ModalCloseButton { dismiss() }
                }
            }
            .task {
                guard DataScannerViewController.isSupported else {
                    isCheckingCamera = false
                    return
                }
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    cameraAuthorized = true
                case .notDetermined:
                    cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
                default:
                    cameraAuthorized = false
                }
                isCheckingCamera = false
            }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                isReadingPhoto = true
                errorMessage = nil
                defer { isReadingPhoto = false }
                do {
                    guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                        errorMessage = "Не удалось открыть фотографию"
                        return
                    }
                    let value = try await Task.detached(priority: .userInitiated) {
                        try BackpackBarcodeReader.serialNumber(in: data)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let value {
                        accept(value)
                    } else {
                        errorMessage = "Штрихкод не найден. Выберите более чёткую фотографию."
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = "Не удалось считать штрихкод"
                }
            }
        }
        .presentationDetents([.large])
    }

    private func accept(_ value: String) {
        guard !hasAcceptedCode, let selection = SerialNumberBarcodeSelection(value) else { return }
        hasAcceptedCode = true
        AppHaptics.trigger()
        onScan(selection.serialNumber)
        dismiss()
    }
}

private struct BackpackLiveBarcodeScanner: UIViewControllerRepresentable {
    let isScanning: Bool
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: BackpackBarcodeReader.symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        context.coordinator.onError = onError
        if isScanning && !scanner.isScanning {
            do {
                try scanner.startScanning()
            } catch {
                context.coordinator.onError("Не удалось запустить камеру. Можно выбрать фото штрихкода.")
            }
        } else if !isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        var onError: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                guard !hasScanned, let value = barcode.payloadStringValue,
                      SerialNumberBarcodeSelection(value) != nil else { continue }
                hasScanned = true
                scanner.stopScanning()
                onScan(value)
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onError("Камера недоступна. Можно выбрать фото штрихкода.")
        }
    }
}
#endif
