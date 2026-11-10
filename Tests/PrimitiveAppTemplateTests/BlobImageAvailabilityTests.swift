import SwiftUI
import XCTest
import JsBaoClientUI

/// The template links the client's SwiftUI product: an app built from it
/// reaches `BlobImage` and `BlobImagePhase` with `import JsBaoClientUI` and
/// no package edit.
final class BlobImageAvailabilityTests: XCTestCase {
    func testBlobImageAndItsPhaseAreReachable() {
        XCTAssertEqual(String(describing: BlobImage<Image>.self), "BlobImage<Image>")
        XCTAssertNil(BlobImagePhase.empty.image)
    }
}
