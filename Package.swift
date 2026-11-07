// swift-tools-version: 6.2
import PackageDescription

// The app target is AppKit / macOS 26. Core and its tests stay buildable on Linux
// so the logic suite can run without a Mac. On macOS the executable is unchanged.
// Linux has no SQLite3 Swift module. macOS imports the SDK module directly,
// so this system target is not part of the Mac build.
#if os(Linux)
let coreDependencies: [Target.Dependency] = ["CSQLite"]
let systemTargets: [Target] = [.systemLibrary(name: "CSQLite")]
#else
let coreDependencies: [Target.Dependency] = []
let systemTargets: [Target] = []
#endif

var products: [Product] = [
    .library(name: "GlassforceCore", targets: ["GlassforceCore"]),
]
var targets: [Target] = systemTargets + [
    .target(name: "GlassforceCore", dependencies: coreDependencies),
    .testTarget(name: "GlassforceCoreTests", dependencies: ["GlassforceCore"]),
]
#if os(macOS)
products.append(.executable(name: "Glassforce", targets: ["Glassforce"]))
targets.append(
    .executableTarget(
        name: "Glassforce",
        dependencies: ["GlassforceCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "Glassforce",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets
)
