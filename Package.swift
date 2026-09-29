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
        .target(name: "md4c", exclude: ["LICENSE.md"]),
        .executableTarget(name: "FAReader", dependencies: ["FACore", "md4c"]),
        .testTarget(name: "FACoreTests", dependencies: ["FACore"], path: "tests"),
    ],
    swiftLanguageModes: [.v5]
)
