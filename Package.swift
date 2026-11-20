// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fulcrum",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FulcrumCore", targets: ["FulcrumCore"])],
    targets: [
        .target(name: "FulcrumCore"),
        .executableTarget(name: "Fulcrum", dependencies: ["FulcrumCore"]),
        .executableTarget(name: "fulcrum-check", dependencies: ["FulcrumCore"]),
    ]
)
