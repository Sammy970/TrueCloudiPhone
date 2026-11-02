// swift-tools-version:5.9
import PackageDescription

// Only the networking module, so it can be unit-tested on the Mac without Xcode project setup.
// The iPhone app compiles Sources/Kit, Sources/Shared and Sources/iOS straight into Moonlight's target
// (see integrate-moonlight.rb).
let package = Package(
    name: "TrueCloudKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TrueCloudKit", targets: ["TrueCloudKit"])],
    targets: [
        .target(name: "TrueCloudKit", path: "Sources/Kit"),
        .testTarget(name: "TrueCloudKitTests", dependencies: ["TrueCloudKit"], path: "Tests/KitTests"),
    ]
)
