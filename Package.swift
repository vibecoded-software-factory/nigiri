// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "nigiri",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nigiri",
            path: "Sources/nigiri",
            exclude: ["Info.plist"],
            swiftSettings: [
                // Everything here runs on the main thread (DispatchQueue.main
                // timers/sources, the NSApplication run loop, AXObserver on
                // the main run loop) - declaring the whole module MainActor
                // by default makes that fact checkable instead of fighting
                // "concurrently-executed" false positives one closure at a
                // time. The @Sendable boundaries (C callbacks, notification
                // blocks) hop back in via MainActor.assumeIsolated.
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/nigiri/Info.plist",
                ])
            ]
        )
    ]
)
