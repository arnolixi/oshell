// swift-tools-version: 6.0
import PackageDescription
import Foundation
let minimum = ProcessInfo.processInfo.environment["OSHELL_LEGACY"] == "1" ? "10.13" : (ProcessInfo.processInfo.environment["OSHELL_MACOS_MINIMUM"] ?? "13.0")
let package = Package(
    name: "SwiftTerm", platforms: [.macOS(minimum)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
                      resources: [.copy("Apple/Metal/Shaders.metal")],
                      swiftSettings: ProcessInfo.processInfo.environment["OSHELL_LEGACY"] == "1" ? [.define("OSHELL_LEGACY")] : [])],
    swiftLanguageModes: [.v5]
)
