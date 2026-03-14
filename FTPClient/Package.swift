// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FTPClient",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "FTPClient",
            targets: ["FTPClient"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.12.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "FTPClient",
            dependencies: [
                .product(name: "NIOCore",      package: "swift-nio"),
                .product(name: "NIOPosix",     package: "swift-nio"),
                .product(name: "NIOSSH",       package: "swift-nio-ssh"),
            ]
        ),
        .testTarget(
            name: "FTPClientTests",
            dependencies: ["FTPClient"]
        ),
    ]
)
