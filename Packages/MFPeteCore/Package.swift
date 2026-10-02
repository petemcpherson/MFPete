// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MFPeteCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFPeteCore", targets: ["MFPeteCore"]),
    ],
    targets: [
        .target(
            name: "MFPeteCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MFPeteCoreTests",
            dependencies: ["MFPeteCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
