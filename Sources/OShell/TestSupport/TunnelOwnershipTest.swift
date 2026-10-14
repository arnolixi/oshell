// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import Darwin
import OShellCore

enum TunnelOwnershipTest {
    static func run(_ workspace: WorkspaceController) {
        let registry = SSHTunnelOwnership(), profile = UUID(), first = UUID(), second = UUID(), third = UUID()
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("oshell-tunnel-test-" + UUID().uuidString)
        var checks = [String: Bool](), fd: Int32 = -1
        defer {
            if fd >= 0 { Darwin.close(fd) }
            try? FileManager.default.removeItem(at: root)
            if let output = ProcessInfo.processInfo.environment["OSHELL_TUNNEL_OWNERSHIP_OUTPUT"] {
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("s").path
            fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw ModelError.invalid("fixture socket") }
            var address = try AuthIPC.address(path)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, listen(fd, 32) == 0 else { throw ModelError.invalid("fixture listen") }
            checks["firstClaimsTunnels"] = registry.acquire(profile: profile, owner: first, controlPath: path)
            checks["pendingLoginBlocksDuplicates"] = !registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            registry.established(profile: profile, owner: first)
            checks["liveTransportBlocksDuplicates"] = !registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            registry.processEnded(profile: profile, owner: first)
            checks["controlPersistOrFileLeaseKeepsOwnership"] = !registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            registry.closing(profile: profile, owner: first)
            checks["liveTransportCannotBeReleasedEarly"] = !registry.finishedClosing(profile: profile, owner: first)
            registry.closing(profile: profile, owner: first)
            Darwin.close(fd); fd = -1
            checks["cleanupInProgressStillReserved"] = !registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            checks["cleanupReleasesStoppedTransport"] = registry.finishedClosing(profile: profile, owner: first)
            checks["nextConnectionCanOwnTunnels"] = registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            registry.processEnded(profile: profile, owner: first)
            _ = registry.finishedClosing(profile: profile, owner: first)
            checks["lateOldCleanupCannotReleaseNewOwner"] = !registry.acquire(profile: profile, owner: third, controlPath: path + "3")
            registry.processEnded(profile: profile, owner: second)
            checks["failedLoginReleasesClaim"] = registry.acquire(profile: profile, owner: third, controlPath: path + "3")
            registry.established(profile: profile, owner: third)
            checks["expiredMasterReclaimedWithoutClosingTab"] = registry.acquire(profile: profile, owner: first, controlPath: path)
            registry.established(profile: profile, owner: first)
            checks["staleSocketDoesNotReserveForever"] = registry.acquire(profile: profile, owner: second, controlPath: path + "2")
            checks["differentConfigurationsRemainIndependent"] = registry.acquire(profile: UUID(), owner: third, controlPath: path + "3")
            let raceProfile = UUID(), counterLock = NSLock(); var winners = 0
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                if registry.acquire(profile: raceProfile, owner: UUID(), controlPath: path + "race") { counterLock.lock(); winners += 1; counterLock.unlock() }
            }
            checks["simultaneousOpensHaveExactlyOneOwner"] = winners == 1
        } catch { checks["fixtureSetup"] = false }
    }
}
