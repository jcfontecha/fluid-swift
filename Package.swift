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
        .target(name: "FluidMergeTree", dependencies: ["FluidJS"]),
        .executableTarget(name: "FluidMergeTreePeer", dependencies: ["FluidMergeTree", "FluidJS"]),
        .testTarget(name: "FluidMergeTreeTests", dependencies: ["FluidMergeTree", "FluidJS"]),
        .target(name: "FluidJS"),
        .target(name: "FluidContainerRuntime", dependencies: ["FluidJS", "FluidLZ4", "FluidDriverDefinitions"]),
        .executableTarget(name: "FluidOpLifecyclePeer", dependencies: ["FluidContainerRuntime", "FluidJS"]),
        .testTarget(name: "FluidContainerRuntimeTests", dependencies: ["FluidContainerRuntime", "FluidJS"]),
        .target(name: "FluidDriverBase", dependencies: ["FluidJS", "FluidSocketIO", "FluidDriverDefinitions"]),
        .target(name: "FluidRouterliciousDriver", dependencies: ["FluidJS", "FluidDriverBase", "FluidDriverDefinitions"]),
        .target(name: "FluidTinyliciousDriver", dependencies: ["FluidJS", "FluidRouterliciousDriver", "FluidDriverDefinitions"]),
        .target(name: "FluidContainerLoader", dependencies: ["FluidJS", "FluidDriverDefinitions", "FluidSocketIO", "FluidDriverBase", "FluidRouterliciousDriver", "FluidTinyliciousDriver"]),
        .executableTarget(name: "FluidServicePeer", dependencies: ["FluidJS", "FluidContainerLoader"]),
        .testTarget(name: "FluidContainerLoaderTests", dependencies: ["FluidJS", "FluidContainerLoader", "FluidTinyliciousDriver", "FluidDriverDefinitions", "FluidDriverBase"]),
        .target(name: "FluidSocketIO", dependencies: ["FluidJS"]),
        .executableTarget(name: "FluidSocketIOCheck", dependencies: ["FluidSocketIO", "FluidJS"]),
        .testTarget(name: "FluidSocketIOTests", dependencies: ["FluidSocketIO", "FluidJS"], resources: [.copy("Fixtures")]),
        .target(name: "CLZ4", publicHeadersPath: "."),
        .target(name: "FluidLZ4", dependencies: ["CLZ4"]),
        .executableTarget(name: "FluidLZ4Check", dependencies: ["FluidLZ4"]),
        .testTarget(name: "FluidLZ4Tests", dependencies: ["FluidLZ4"]),
        .target(name: "FluidDriverDefinitions", dependencies: ["FluidJS"]),
        .target(name: "FluidDatastoreDefinitions", dependencies: ["FluidJS", "FluidDriverDefinitions"]),
        .target(name: "FluidCounter", dependencies: ["FluidJS", "FluidDriverDefinitions", "FluidDatastoreDefinitions"]),
        .target(name: "FluidTestRuntimeUtils", dependencies: ["FluidJS", "FluidDriverDefinitions", "FluidDatastoreDefinitions"]),
        .executableTarget(
            name: "FluidSwiftPeer",
            dependencies: ["FluidJS", "FluidDriverDefinitions", "FluidDatastoreDefinitions", "FluidCounter", "FluidTestRuntimeUtils"]
        ),
        .testTarget(name: "FluidDriverDefinitionsTests", dependencies: ["FluidDriverDefinitions", "FluidJS"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FluidJSTests", dependencies: ["FluidJS"]),
    ]
)
