// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorDepthCapture",
    // Must stay at 15: the app target Capacitor generates for SPM is iOS 15,
    // and a higher floor here fails the whole build.
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorDepthCapture",
            targets: ["DepthCapturePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "DepthCapturePlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Plugin",
            resources: [
                .process("furniture_labels.json")
            ])
    ]
)
