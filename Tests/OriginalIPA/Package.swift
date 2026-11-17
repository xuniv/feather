// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OriginalIPAChecks", platforms: [.macOS(.v12)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [.executableTarget(name: "OriginalIPAChecks", dependencies: [.product(name: "ZIPFoundation", package: "zipfoundation")], path: "Sources")])
