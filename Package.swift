// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenBar", targets: ["TokenBar"])
    ],
    targets: [
        .executableTarget(
            name: "TokenBar",
            path: "Sources/TokenBar",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBar"],
            path: "Tests/TokenBarTests"
        )
    ]
)
