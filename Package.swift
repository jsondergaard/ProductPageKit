// swift-tools-version: 6.2
import PackageDescription

// ProductPageKit keeps an app's App Store product page in its repository:
// screenshots, videos, text metadata, release notes and in-app products.
//
// - ProductPageKitCapture: what an app links, DEBUG only. Its scenes, the
//   director that moves between them, and the ready signal. Built on
//   ProductPageKitControl, the wire protocol it and the runner share.
// - ProductPageKitFrames: drawing for framed screenshots and videos: the
//   canvas, device bezels, text columns, grain, and the video compositor.
//   Knows nothing of App Store Connect or projects.
// - ProductPageKitCore: project configuration, store locales and platforms,
//   the frame and motion themes, the String Catalog, Apple's field limits,
//   the product catalogue, the StoreKit configuration file and the cache.
//   No network.
// - ProductPageKitASC: the App Store Connect API client, generated from
//   Apple's OpenAPI document, and the operations built on it.
// - ProductPageKitRunner: builds the app, drives simulators and the Mac app
//   through the control protocol, and writes raw captures to the cache.
// - ProductPageKit: the commands, and `ProductPageKit.main(project)` for each
//   app's tools executable.

// Imports are internal unless marked, so a module's public API names every
// module it exposes. The generated client imports at `package` level.
let settings: [SwiftSetting] = [.enableUpcomingFeature("InternalImportsByDefault")]

let package = Package(
    name: "ProductPageKit",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "ProductPageKit", targets: ["ProductPageKit"]),
        .library(name: "ProductPageKitCapture", targets: ["ProductPageKitCapture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
    ],
    targets: [
        .target(name: "ProductPageKitControl", swiftSettings: settings),
        .target(name: "ProductPageKitCapture", dependencies: ["ProductPageKitControl"], swiftSettings: settings),
        .target(name: "ProductPageKitFrames", swiftSettings: settings),
        .target(name: "ProductPageKitCore", dependencies: ["ProductPageKitFrames"], swiftSettings: settings),
        .target(
            name: "ProductPageKitASC",
            dependencies: [
                "ProductPageKitCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: settings,
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .target(
            name: "ProductPageKitRunner",
            dependencies: ["ProductPageKitCore", "ProductPageKitControl"],
            swiftSettings: settings
        ),
        .target(
            name: "ProductPageKit",
            dependencies: [
                "ProductPageKitCore",
                "ProductPageKitFrames",
                "ProductPageKitASC",
                "ProductPageKitRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Review/review.html")],
            swiftSettings: settings
        ),
        .testTarget(name: "ProductPageKitCaptureTests", dependencies: ["ProductPageKitCapture", "ProductPageKitControl", "ProductPageKitCore"]),
        // Golden image comparison, shared by the test targets that draw.
        .target(name: "ProductPageKitTestSupport", path: "Tests/Support", swiftSettings: settings),
        // `Golden` reads its images from beside the test's source, not a bundle.
        .testTarget(name: "ProductPageKitFramesTests", dependencies: ["ProductPageKitFrames", "ProductPageKitTestSupport"],
                    exclude: ["Golden"]),
        .testTarget(name: "ProductPageKitCoreTests", dependencies: ["ProductPageKitCore", "ProductPageKitFrames"]),
        .testTarget(
            name: "ProductPageKitRunnerTests",
            dependencies: ["ProductPageKitRunner", "ProductPageKitCore", "ProductPageKitControl"]
        ),
        .testTarget(
            name: "ProductPageKitASCTests",
            dependencies: [
                "ProductPageKitASC",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        .testTarget(
            name: "ProductPageKitTests",
            dependencies: [
                "ProductPageKit",
                "ProductPageKitRunner",
                "ProductPageKitTestSupport",
                "ProductPageKitASC",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            exclude: ["Golden"]
        ),
    ]
)
