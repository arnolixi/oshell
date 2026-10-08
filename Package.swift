// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import PackageDescription
import Foundation
let legacy = ProcessInfo.processInfo.environment["OSHELL_LEGACY"] == "1"
let minimum = legacy ? "10.13" : (ProcessInfo.processInfo.environment["OSHELL_MACOS_MINIMUM"] ?? "13.0")
let compatibility: [SwiftSetting] = legacy ? [.define("OSHELL_LEGACY")] : []
let package = Package(
    name: "OShell", platforms: [.macOS(minimum)],
    products: [.executable(name: "OShell", targets: ["OShell"]), .executable(name: "OShell-ZOC", targets: ["OShellZOC"]), .executable(name: "OShell-FileZilla", targets: ["OShellFileZilla"])],
    dependencies: [.package(path: "Vendor/SwiftTerm")] + (legacy ? [.package(path: "Vendor/CryptoSwift")] : []),
    targets: [
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .target(name: "OShellCore", dependencies: legacy ? [.product(name: "CryptoSwift", package: "CryptoSwift")] : [], swiftSettings: compatibility),
        .executableTarget(name: "OShell", dependencies: ["OShellCore", "Sparkle", .product(name: "SwiftTerm", package: "SwiftTerm")], swiftSettings: compatibility, linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "OShellSSH"),
        .executableTarget(name: "OShellProxy", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellAskpass", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellZOC", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellFileZilla", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellCoreChecks", dependencies: ["OShellCore"], path: "Tests/OShellCoreTests")
    ], swiftLanguageModes: [.v5]
)
