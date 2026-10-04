// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WatchRemoteCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "WatchRemoteCore", targets: ["WatchRemoteCore"]),
    ],
    targets: [
        .target(name: "WatchRemoteCore"),
    ]
)
