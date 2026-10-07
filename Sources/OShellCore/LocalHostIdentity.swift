// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin
import SystemConfiguration

/// The local shell uses the same host/IP model as remote shells, without DNS.
public enum LocalHostIdentity {
    public static func current() -> RemoteHostIdentity {
        var name = [CChar](repeating: 0, count: 256)
        let hostname = gethostname(&name, name.count) == 0 ? String(cString: name) : ProcessInfo.processInfo.hostName
        var primary = Set<String>()
        for family in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let device = state["PrimaryInterface"] as? String { primary.insert(device) }
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        var candidates = [(rank: Int, address: String)]()
        if getifaddrs(&head) == 0 {
            defer { freeifaddrs(head) }
            var cursor = head
            while let entry = cursor {
                let item = entry.pointee; cursor = item.ifa_next
                guard let address = item.ifa_addr, item.ifa_flags & UInt32(IFF_UP) != 0,
                      item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
                let family = Int32(address.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(cString: buffer), device = String(cString: item.ifa_name)
                guard RemoteHostIdentity.address(ip) != nil, !ip.hasPrefix("169.254."), !ip.lowercased().hasPrefix("fe80:") else { continue }
                let rank = (primary.contains(device) ? 0 : 4) + (family == AF_INET ? 0 : 1)
                candidates.append((rank, ip))
            }
        }
        let address = candidates.sorted { $0.rank == $1.rank ? $0.address < $1.address : $0.rank < $1.rank }.first?.address
        return RemoteHostIdentity(hostname: hostname, address: address)
    }
}
