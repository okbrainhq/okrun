// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OkrunVM",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OkrunVM", targets: ["OkrunVM"])
    ],
    targets: [
        .executableTarget(
            name: "OkrunVM",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Virtualization")
            ]
        ),
        .testTarget(
            name: "OkrunVMTests",
            dependencies: ["OkrunVM"],
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
