// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pwnd",
    platforms: [.macOS(.v14)],
    targets: [
        // Feed parsing, keyword scoring and polling. No UI, so it can be tested
        // and driven from the command line.
        .target(name: "PwndCore", path: "Sources/PwndCore"),
        // The macOS app: window, menu bar item, notifications.
        .executableTarget(
            name: "Pwnd",
            dependencies: ["PwndCore"],
            path: "Sources/Pwnd"
        ),
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
)
