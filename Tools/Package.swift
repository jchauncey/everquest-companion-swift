// swift-tools-version: 6.0
// The developer tools, kept out of the app package so a bare `swift run` at the root means the app.
//   swift run --package-path Tools eqtool events --all
//   swift run --package-path Tools eqbench <log>
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "EQCompanionTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "eqtool", targets: ["EQTool"]),
        .executable(name: "eqbench", targets: ["EQBench"])
    ],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "EQTool",
                          dependencies: [.product(name: "EQLog", package: "everquest-companion-swift"),
                                         .product(name: "EQFold", package: "everquest-companion-swift"),
                                         .product(name: "EQEngine", package: "everquest-companion-swift"),
                                         .product(name: "EQCompanionCore", package: "everquest-companion-swift")],
                          path: "Sources/EQTool", swiftSettings: v5),
        .executableTarget(name: "EQBench",
                          dependencies: [.product(name: "EQLog", package: "everquest-companion-swift")],
                          path: "Sources/EQBench", swiftSettings: v5)
    ]
)
