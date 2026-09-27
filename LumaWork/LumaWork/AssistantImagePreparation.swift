import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct AssistantPreparedImagePayload: Sendable {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
}

enum AssistantImagePreparationError: LocalizedError {
    case invalidImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Не удалось подготовить изображение."
        case .imageTooLarge:
            "Изображение слишком большое для отправки."
        }
    }
}

enum AssistantImagePreparer {
    nonisolated private static let maximumPixelSize = 1_800
    nonisolated private static let maximumBytes = 4 * 1_024 * 1_024

    static func prepare(data: Data) async throws -> AssistantPreparedImagePayload {
        try await Task.detached(priority: .userInitiated) {
            try prepareSynchronously(data: data)
        }.value
    }

    nonisolated private static func prepareSynchronously(data: Data) throws -> AssistantPreparedImagePayload {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw AssistantImagePreparationError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AssistantImagePreparationError.invalidImage
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AssistantImagePreparationError.invalidImage
        }

        let preparedData = output as Data
        guard preparedData.count <= maximumBytes else {
            throw AssistantImagePreparationError.imageTooLarge
        }
        return AssistantPreparedImagePayload(
            data: preparedData,
            mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            width: image.width,
            height: image.height
        )
    }
}
