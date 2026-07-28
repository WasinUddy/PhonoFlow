// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PhonoFlowCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "PhonoFlowCore", targets: ["PhonoFlowCore"]),
        .executable(name: "PhonoFlowBenchmarks", targets: ["PhonoFlowBenchmarks"]),
    ],
    targets: [
        .target(
            name: "PhonoFlowCore",
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "PhonoFlowBenchmarks",
            dependencies: ["PhonoFlowCore"]
        ),
        .testTarget(
            name: "PhonoFlowCoreTests",
            dependencies: ["PhonoFlowCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
