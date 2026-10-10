// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Perch", targets: ["Perch"])],
    targets: [
        .target(name: "PerchCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Perch", dependencies: ["PerchCore"]),
        .testTarget(name: "PerchCoreTests", dependencies: ["PerchCore"]),
        .testTarget(name: "PerchTests", dependencies: ["Perch"])
    ],
    swiftLanguageModes: [.v5]
)
