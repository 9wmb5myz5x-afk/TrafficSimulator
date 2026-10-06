// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrafficEngine",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        // Pure simulation engine (no UI, no Foundation): used by the app,
        // the CLI and the tests.
        .library(name: "TrafficEngine", targets: ["TrafficEngine"]),
        .executable(name: "trafficsim", targets: ["trafficsim"])
    ],
    targets: [
        .target(
            name: "TrafficEngine",
            path: "Sources/TrafficEngine",
            swiftSettings: [
                // The step loop mutates the simulation's arrays in place millions
                // of times a second; dynamic exclusivity checks on those class
                // properties cost ~20 % in release builds. Debug builds keep them.
                .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "trafficsim",
            dependencies: ["TrafficEngine"],
            path: "Sources/trafficsim"
        ),
        .testTarget(
            name: "TrafficEngineTests",
            dependencies: ["TrafficEngine"],
            path: "Tests/TrafficEngineTests"
        )
    ]
)
