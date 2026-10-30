import Foundation
import ImageIO
import UniformTypeIdentifiers
import JsBaoClient

/// An avatar image ready for `client.me.uploadAvatar`.
///
/// `prepare(_:)` takes whatever the photo picker returned: a PNG, JPEG, GIF or
/// WebP that already fits the server's limit uploads as it is, and anything
/// else ImageIO can read (a HEIC photo, a large JPEG) is scaled down and sent
/// as JPEG.
struct AvatarImage: Equatable, Sendable {
    let data: Data
    let contentType: AvatarContentType

    /// The largest file the editor accepts from the picker.
    static let maxPickedBytes = 20 * 1024 * 1024
    /// The largest upload the server accepts.
    static let maxUploadBytes = 1024 * 1024

    static func prepare(_ data: Data) -> Result<AvatarImage, AvatarImageError> {
        guard data.count <= maxPickedBytes else { return .failure(.tooLarge) }
        if let type = sniff(data), data.count <= maxUploadBytes {
            return .success(AvatarImage(data: data, contentType: type))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return .failure(.notAnImage) }
        for maxPixels in [1024, 512, 256] {
            if let jpeg = jpeg(from: source, maxPixels: maxPixels), jpeg.count <= maxUploadBytes {
                return .success(AvatarImage(data: jpeg, contentType: .jpeg))
            }
        }
        return .failure(.notAnImage)
    }

    /// The format the bytes' signature names, among the four the server takes.
    static func sniff(_ data: Data) -> AvatarContentType? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return .gif }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return .webp
        }
        return nil
    }

    private static func jpeg(from source: CGImageSource, maxPixels: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// Why a picked file cannot be an avatar.
enum AvatarImageError: Error, Equatable, LocalizedError {
    case notAnImage
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "That file is not an image. Choose a photo."
        case .tooLarge: return "That image is larger than 20 MB. Choose a smaller one."
        }
    }
}

extension AppState {
    /// Save the profile the way the web template's editor does: upload the
    /// avatar first, then the name, then re-read the profile. A blank name is
    /// left as it is. Throws the first failure; nothing after it runs, so a
    /// refused avatar leaves the previous one in place.
    func saveProfile(name: String, avatar: AvatarImage?) async throws {
        guard let client else { throw JsBaoError(code: .unavailable, message: "The client is not initialized") }
        if let avatar {
            _ = try await client.me.uploadAvatar(imageData: avatar.data, contentType: avatar.contentType)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = try await client.me.update(params: UpdateMeParams(name: trimmed))
        }
        await refreshProfile()
    }

    /// The message a failed profile save shows: the server's own words when
    /// it sent any.
    static func saveFailureMessage(_ error: Error) -> String {
        AuthModel.serverMessage(of: error) ?? error.localizedDescription
    }
}
