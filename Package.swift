// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Radar",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Radar", targets: ["Radar"])],
    dependencies: [
        .package(path: "ThirdParty/GRDB.swift"),
        .package(url: "https://github.com/nmdias/FeedKit", from: "9.1.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    ],
    targets: [
        .target(name: "RadarCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            "FeedKit", "SwiftSoup",
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Radar", dependencies: ["RadarCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RadarCoreTests", dependencies: ["RadarCore"],
                    resources: [.copy("fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
