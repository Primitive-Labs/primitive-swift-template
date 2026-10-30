import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// Images the profile tests upload.
enum TestImages {
    /// A 1×1 PNG.
    static let pixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    static var pixel: AvatarImage {
        guard case .success(let image) = AvatarImage.prepare(pixelPNG) else { fatalError("the test PNG did not prepare") }
        return image
    }

    /// PNG-signed bytes past the server's upload limit, which the server refuses.
    static var oversized: AvatarImage {
        AvatarImage(data: pixelPNG + Data(count: AvatarImage.maxUploadBytes + 1), contentType: .png)
    }
}

/// Saving the profile: the avatar and the name, and what a refusal leaves.
@MainActor
final class ProfileTests: XCTestCase {
    func testSavingUploadsTheAvatarAndRoundTripsTheName() async throws {
        let app = try await TestApp.signedIn()
        let name = "Profile \(UUID().uuidString.prefix(6))"
        try await app.saveProfile(name: name, avatar: TestImages.pixel)
        XCTAssertEqual(app.userName, name)
        let avatarUrl = try XCTUnwrap(app.userAvatarUrl)
        let profile = try await XCTUnwrap(app.client).me.get()
        XCTAssertEqual(profile?.name, name)
        XCTAssertEqual(profile?.avatarUrl, avatarUrl)
        await TestApp.tearDown(app)
    }

    func testARefusedAvatarShowsTheServersMessageAndKeepsTheOldOne() async throws {
        let app = try await TestApp.signedIn()
        try await app.saveProfile(name: "", avatar: TestImages.pixel)
        let previous = try XCTUnwrap(app.userAvatarUrl)
        do {
            try await app.saveProfile(name: "", avatar: TestImages.oversized)
            XCTFail("the server took an oversized avatar")
        } catch {
            let message = AppState.saveFailureMessage(error)
            XCTAssertTrue(message.localizedCaseInsensitiveContains("too large"), message)
        }
        XCTAssertEqual(app.userAvatarUrl, previous)
        await TestApp.tearDown(app)
    }

    func testThePickerAcceptsImagesAndRefusesTheRest() {
        guard case .success(let png) = AvatarImage.prepare(TestImages.pixelPNG) else { return XCTFail("PNG refused") }
        XCTAssertEqual(png.contentType, .png)
        XCTAssertEqual(png.data, TestImages.pixelPNG)

        XCTAssertEqual(AvatarImage.prepare(Data("not an image".utf8)), .failure(.notAnImage))
        XCTAssertEqual(AvatarImage.prepare(Data(count: AvatarImage.maxPickedBytes + 1)), .failure(.tooLarge))

        XCTAssertEqual(AvatarImage.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(AvatarImage.sniff(Data("GIF89a......".utf8)), .gif)
        XCTAssertEqual(AvatarImage.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webp)
        XCTAssertNil(AvatarImage.sniff(Data("hello".utf8)))
    }

    func testALargePhotoIsScaledDownToFitTheUploadLimit() throws {
        let big = try TestImages.jpeg(width: 1600, height: 1200)
        XCTAssertGreaterThan(big.count, AvatarImage.maxUploadBytes)
        XCTAssertLessThan(big.count, AvatarImage.maxPickedBytes)
        let result = AvatarImage.prepare(big)
        guard case .success(let prepared) = result else { return XCTFail("a \(big.count)-byte photo was refused: \(result)") }
        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertLessThanOrEqual(prepared.data.count, AvatarImage.maxUploadBytes)
    }
}

extension TestImages {
    /// A noisy JPEG, so it does not compress below the upload limit.
    static func jpeg(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 42
        for i in 0..<pixels.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
