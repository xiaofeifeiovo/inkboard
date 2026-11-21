// swift-tools-version:5.9
// `swift run Inkboard` for development; scripts/build.sh builds the same sources and packages Inkboard.app.
import PackageDescription

let package = Package(
    name: "Inkboard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Inkboard", targets: ["Inkboard"]),
    ],
    targets: [
        // Pure model / geometry / rendering. No AppKit, so it can be reused (e.g. by an AI export pipeline).
        .target(name: "InkboardCore"),
        // The macOS app (AppKit).
        .executableTarget(
            name: "Inkboard",
            dependencies: ["InkboardCore"],
            linkerSettings: [
                // Embed Info.plist so an unbundled `swift run` binary still declares the .inkboard
                // document type (NSDocumentController reads CFBundleDocumentTypes from it).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist"]),
            ]
        ),
        // Self-check: assertions on the core logic + renders a sample PNG.
        // (Command Line Tools ship without XCTest, so this stands in for a test target.)
        .executableTarget(name: "InkboardCheck", dependencies: ["InkboardCore"]),
    ]
)
