// swift-tools-version: 5.9
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
        .package(url: "https://github.com/Primitive-Labs/swift-primitive-app.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "PrimitiveAppTemplate",
            dependencies: [
                .product(name: "PrimitiveApp", package: "PrimitiveApp"),
            ],
            path: "Sources/PrimitiveAppTemplate"
        ),
    ]
)
