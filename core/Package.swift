// swift-tools-version:5.10
// TripCore — pure business logic, no Apple UI/sensor frameworks.
// Must build and test on Windows, Linux and macOS: `swift test`.
import PackageDescription

let package = Package(
    name: "TripCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "TripCore", targets: ["TripCore"])
    ],
    targets: [
        .target(
            name: "TripCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TripCoreTests",
            dependencies: ["TripCore"]
        )
    ]
)
