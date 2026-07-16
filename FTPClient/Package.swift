// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FTPClient",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "FTPClient",
            targets: ["FTPClient"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "FTPClient",
            dependencies: [
                .product(name: "NIO",            package: "swift-nio"),
                .product(name: "NIOCore",        package: "swift-nio"),
                .product(name: "NIOPosix",       package: "swift-nio"),
                .product(name: "NIOSSH",         package: "swift-nio-ssh"),
                .product(name: "Crypto",         package: "swift-crypto"),
                .product(name: "Logging",        package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "FTPClientTests",
            dependencies: [
                "FTPClient",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
