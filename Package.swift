// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeOpsTracker",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "ForgeOpsTracker", targets: ["ForgeOpsTracker"])
    ],
    targets: [
        // A small C target for exactly one thing: the fatal-signal handler. See its own header
        // comment (Sources/CFOTSignal/include/cfot_signal.h) for why that specifically can't be
        // pure Swift.
        .target(name: "CFOTSignal"),
        .target(name: "ForgeOpsTracker", dependencies: ["CFOTSignal"]),
        // Test-only Objective-C helper (raises and catches a real NSException so its
        // -callStackSymbols is populated) -- see its own header comment for why this can't be
        // Swift. Lives under Tests/ via an explicit path so it's never part of the shipped
        // library.
        .target(name: "CFOTTestSupport", path: "Tests/CFOTTestSupport"),
        .testTarget(name: "ForgeOpsTrackerTests", dependencies: ["ForgeOpsTracker", "CFOTTestSupport"]),
    ]
)
