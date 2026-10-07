// swift-tools-version: 6.0
import PackageDescription
import Foundation
let package = Package(
    name: "SwiftTerm", platforms: [.macOS(ProcessInfo.processInfo.environment["OSHELL_LEGACY"] == "1" ? .v10_13 : .v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
                      resources: [.copy("Apple/Metal/Shaders.metal")],
                      swiftSettings: ProcessInfo.processInfo.environment["OSHELL_LEGACY"] == "1" ? [.define("OSHELL_LEGACY")] : [])],
    swiftLanguageModes: [.v5]
)
