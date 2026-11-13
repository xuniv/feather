// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InstallationIntegration",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/vapor/vapor", exact: "4.104.0")],
    targets: [.executableTarget(name: "InstallationIntegration", dependencies: [
        .product(name: "Vapor", package: "vapor")
    ], path: "Sources")]
)
