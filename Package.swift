// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PrimitiveAppTemplate",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "primitive-app-template", targets: ["PrimitiveAppTemplate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Primitive-Labs/swift-client.git", branch: "alpha"),
    ],
    targets: [
        .executableTarget(
            name: "PrimitiveAppTemplate",
            dependencies: [
                .product(name: "JsBaoClient", package: "swift-client"),
            ],
            path: "Sources/PrimitiveAppTemplate",
            // `Models/Generated/` is compiled as committed: `scripts/codegen.sh`
            // regenerates it on every scripted and Xcode build path, and a bare
            // `swift build` compiles what is there. `bao-codegen.json` names
            // the db3 type file codegen reads; it is not a source.
            exclude: ["Models/Generated/README.md", "bao-codegen.json"]
        ),
        // The app's tests: `./test.sh` runs them on the Mac, signed in as the
        // test account through `Tests/PrimitiveAppTemplateTests/Support/SignIn.swift`.
        // They reach the app's own types with `@testable import PrimitiveAppTemplate`.
        .testTarget(
            name: "PrimitiveAppTemplateTests",
            dependencies: [
                "PrimitiveAppTemplate",
                .product(name: "JsBaoClient", package: "swift-client"),
            ],
            path: "Tests/PrimitiveAppTemplateTests"
        ),
    ],
    // Swift 6 language mode for the whole package (#2310). Strict concurrency
    // checking is `complete` and its diagnostics are hard errors, matching the
    // JsBaoClient package this template builds on.
    swiftLanguageModes: [.v6]
)
