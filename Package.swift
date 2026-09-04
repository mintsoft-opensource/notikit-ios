// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notikit",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "Notikit", targets: ["Notikit"])
    ],
    targets: [
        .target(name: "Notikit"),
        .testTarget(name: "NotikitTests", dependencies: ["Notikit"])
    ]
)
