// swift-tools-version:5.9
import PackageDescription

// SalesCentral — Swift SDK for the SalesCentral backend.
//
// Single-target library. No third-party dependencies; everything is built
// against Foundation, StoreKit 2, UIKit (iOS), and Security (Keychain).
//
// Minimum platforms reflect StoreKit 2's availability.

let package = Package(
    name: "SalesCentral",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SalesCentral", targets: ["SalesCentral"]),
    ],
    targets: [
        .target(
            name: "SalesCentral",
            path: "Sources/SalesCentral"
        ),
        .testTarget(
            name: "SalesCentralTests",
            dependencies: ["SalesCentral"],
            path: "Tests/SalesCentralTests"
        ),
    ]
)
