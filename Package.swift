// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fa-reader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FAReader", targets: ["FAReader"]),
        .library(name: "FACore", targets: ["FACore"]),
    ],
    targets: [
        .target(name: "FACore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FAReader", dependencies: ["FACore"]),
        .testTarget(name: "FACoreTests", dependencies: ["FACore"], path: "tests"),
    ],
    swiftLanguageModes: [.v5]
)
