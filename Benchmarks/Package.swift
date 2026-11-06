// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FluidBenchmarks",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(name: "FluidSwift", path: "..")],
    targets: [
        .target(name: "BenchCounter", dependencies: [.product(name: "FluidContainerLoader", package: "FluidSwift")], path: "Sources/FluidCounter"),
        .target(name: "BenchMergeTree", dependencies: [.product(name: "FluidContainerLoader", package: "FluidSwift")], path: "Sources/FluidMergeTree"),
        .target(name: "BenchSequence", dependencies: ["BenchMergeTree", .product(name: "FluidContainerLoader", package: "FluidSwift")], path: "Sources/FluidSequence", swiftSettings: [.unsafeFlags(["-module-alias", "FluidMergeTree=BenchMergeTree"])]),
        .target(name: "BenchTestRuntimeUtils", dependencies: [.product(name: "FluidContainerLoader", package: "FluidSwift")], path: "Sources/FluidTestRuntimeUtils"),
        .executableTarget(name: "FluidBench", dependencies: ["BenchCounter", "BenchSequence", "BenchTestRuntimeUtils", .product(name: "FluidContainerLoader", package: "FluidSwift"), .product(name: "FluidMap", package: "FluidSwift")])
    ]
)
