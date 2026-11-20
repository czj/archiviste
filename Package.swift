// swift-tools-version: 6.4
import PackageDescription

/// Swift 6 language mode with Approachable Concurrency: `async` runs on the caller's actor,
/// `@concurrent` is the explicit way off it.
let approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]
/// The app and the CLI live on the main actor; the library stays nonisolated so callers decide.
let mainActorByDefault = approachable + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "archiviste",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "archiviste", targets: ["archiviste"]),
        .executable(name: "ArchivisteApp", targets: ["ArchivisteApp"]),
    ],
    targets: [
        .target(name: "ArchivisteCore", swiftSettings: approachable),
        .executableTarget(name: "archiviste", dependencies: ["ArchivisteCore"], swiftSettings: mainActorByDefault),
        .executableTarget(name: "ArchivisteApp", dependencies: ["ArchivisteCore"], swiftSettings: mainActorByDefault),
        .testTarget(name: "ArchivisteCoreTests", dependencies: ["ArchivisteCore"],
                    resources: [.copy("Fixtures")], swiftSettings: approachable),
    ]
)
