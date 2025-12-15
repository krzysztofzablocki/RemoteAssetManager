// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RemoteAssetManager",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "RemoteAssetManager",
            targets: ["RemoteAssetManager"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "6.2.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "RemoteAssetManager",
            dependencies: []
        ),
        .testTarget(
            name: "RemoteAssetManagerTests",
            dependencies: [
                "RemoteAssetManager",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
