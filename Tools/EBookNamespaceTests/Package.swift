// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "EBookNamespace", targets: [
    .target(name: "EBookNamespace", path: "Sources"),
    .testTarget(name: "EBookNamespaceTests", dependencies: ["EBookNamespace"], path: "Tests")
])
