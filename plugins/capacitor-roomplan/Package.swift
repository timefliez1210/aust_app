// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorRoomplan",
    // RoomPlan is iOS 16+. CI raises the generated app target to 16 before
    // `cap sync` (scripts/ios-deployment-target.sh) — Capacitor's default of 15
    // would fail the build against this floor.
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "CapacitorRoomplan",
            targets: ["RoomPlanPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "RoomPlanPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Plugin")
    ]
)
