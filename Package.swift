// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Sparkle is opt-in at build time: CLIPVELOPE_SPARKLE=1 swift build
//
// Embedding it is not free. macOS refuses to load a framework into a process
// unless both carry the same Apple team identifier, and ad-hoc and self-signed
// signatures have none — measured, the app dies at launch with "different Team
// IDs". So a build with Sparkle can only run when signed with a real Apple
// identity, which CI does not have and a contributor without a certificate does
// not either.
//
// Making it conditional keeps `swift build`, the tests and CI working for
// everyone, and turns the updater on for the signed builds that are actually
// distributed.
let sparkleEnabled = ProcessInfo.processInfo.environment["CLIPVELOPE_SPARKLE"] == "1"

let package = Package(
    name: "Clipvelope",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Clipvelope", targets: ["Clipvelope"])
    ],
    dependencies: sparkleEnabled ? [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ] : [],
    targets: [
        .executableTarget(
            name: "Clipvelope",
            dependencies: sparkleEnabled
                ? [.product(name: "Sparkle", package: "Sparkle")]
                : [],
            path: "Sources/Clipvelope",
            swiftSettings: sparkleEnabled ? [.define("SPARKLE")] : []
        ),
        .testTarget(
            name: "ClipvelopeTests",
            dependencies: ["Clipvelope"],
            path: "Tests/ClipvelopeTests"
        )
    ]
)
