// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FluidSwift",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FluidCounter", targets: ["FluidCounter"]),
        .executable(name: "fluid-swift-peer", targets: ["FluidSwiftPeer"]),
    ],
    targets: [
        .target(name: "FluidJS"),
        .target(name: "FluidProtocol", dependencies: ["FluidJS"]),
        .target(name: "FluidDatastoreDefinitions", dependencies: ["FluidJS", "FluidProtocol"]),
        .target(name: "FluidCounter", dependencies: ["FluidJS", "FluidProtocol", "FluidDatastoreDefinitions"]),
        .target(name: "FluidTestRuntimeUtils", dependencies: ["FluidJS", "FluidProtocol", "FluidDatastoreDefinitions"]),
        .executableTarget(
            name: "FluidSwiftPeer",
            dependencies: ["FluidJS", "FluidProtocol", "FluidDatastoreDefinitions", "FluidCounter", "FluidTestRuntimeUtils"]
        ),
        .testTarget(name: "FluidJSTests", dependencies: ["FluidJS"]),
    ]
)
