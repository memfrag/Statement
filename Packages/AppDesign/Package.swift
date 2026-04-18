// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppDesign",
    platforms: [
        .iOS(.v26), .macOS(.v26), .tvOS(.v26), .visionOS(.v26)
    ],
    products: [
        .library(name: "AppDesign", targets: ["AppDesign"])
    ],
    targets: [
        .target(name: "AppDesign", dependencies: [])
    ]
)
