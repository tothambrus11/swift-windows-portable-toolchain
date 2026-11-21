// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "CApp",
  targets: [
    .target(name: "CHelper", path: "Sources/CHelper"),
    .executableTarget(name: "CApp", dependencies: ["CHelper"], path: "Sources/CApp"),
  ]
)
