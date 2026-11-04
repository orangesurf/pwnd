// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Feed parsing, keyword scoring and polling. No UI, so it can be tested
    // and driven from the command line, on Linux too (CI runs the tests there).
    .target(name: "PwndCore", path: "Sources/PwndCore"),
    // `swift run pwnd-scan <owner/repo|url>...` fetches feeds once and prints
    // how each entry scores. Used to tune the keyword lists.
    .executableTarget(
        name: "pwnd-scan",
        dependencies: ["PwndCore"],
        path: "Sources/pwnd-scan"
    ),
    .testTarget(
        name: "PwndCoreTests",
        dependencies: ["PwndCore"],
        path: "Tests/PwndCoreTests"
    ),
]

#if os(macOS)
// The macOS app: window, menu bar item, notifications. SwiftUI and AppKit only
// exist on Apple platforms, so the target is left out elsewhere.
targets.append(
    .executableTarget(
        name: "Pwnd",
        dependencies: ["PwndCore"],
        path: "Sources/Pwnd"
    )
)
#endif

let package = Package(
    name: "Pwnd",
    platforms: [.macOS(.v14)],
    targets: targets
)
