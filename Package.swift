// swift-tools-version: 6.0
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
        .package(url: "https://github.com/Primitive-Labs/swift-primitive-app.git", branch: "alpha"),
        // Direct `JsBaoClient` dep so the build-tool plugin reference
        // below resolves. The same package is pulled in transitively
        // through `PrimitiveApp`, but SPM plugin references must name a
        // package the consuming manifest depends on directly.
        .package(url: "https://github.com/Primitive-Labs/swift-client.git", branch: "alpha"),
    ],
    targets: [
        .executableTarget(
            name: "PrimitiveAppTemplate",
            dependencies: [
                .product(name: "PrimitiveApp", package: "swift-primitive-app"),
            ],
            path: "Sources/PrimitiveAppTemplate",
            // The Xcode build path runs `swift-bao-codegen` itself — from
            // the target's pre-build phase, and from `run-ios.sh` before
            // it regenerates the project — writing into `Models/Generated/`
            // so xcodegen can scan it into the .pbxproj. The SPM plugin
            // emits its own copies into the plugin work dir on `swift build`.
            // Exclude the manual-output dir from SPM's view so the two
            // producers don't collide.
            exclude: ["Models/Generated"],
            plugins: [
                .plugin(name: "JsBaoCodegenPlugin", package: "swift-client"),
            ]
        ),
    ],
    // Swift 6 language mode for the whole package (#2310). Strict concurrency
    // checking is `complete` and its diagnostics are hard errors, matching the
    // JsBaoClient package this template builds on.
    swiftLanguageModes: [.v6]
)
