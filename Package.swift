// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nearby",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Nearby", targets: ["Nearby"]),
        .library(name: "NearbyCore", targets: ["NearbyCore"])
    ],
    targets: [
        .target(
            name: "NearbyCore",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "Nearby",
            dependencies: ["NearbyCore"],
            resources: [.copy("Resources/Runtime")]
        ),
        .testTarget(name: "NearbyCoreTests", dependencies: ["NearbyCore"]),
        .testTarget(name: "NearbyAppTests", dependencies: ["Nearby", "NearbyCore"])
    ],
    swiftLanguageModes: [.v6]
)
