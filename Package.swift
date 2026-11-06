// swift-tools-version:5.9
// Used for the Core unit tests. The app itself is built by install.command,
// which compiles Sources/Core and Sources/App together into one program.
import PackageDescription

let package = Package(
    name: "MailDock",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MailDockCore", path: "Sources/Core"),
        .testTarget(name: "CoreTests", dependencies: ["MailDockCore"], path: "Tests/CoreTests"),
    ]
)
