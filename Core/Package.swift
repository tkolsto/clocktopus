// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClocktopusCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClocktopusCore", targets: ["ClocktopusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "ClocktopusCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .testTarget(name: "ClocktopusCoreTests", dependencies: ["ClocktopusCore"]),
    ]
)
