// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public enum FileSessionAddress {
    /// File protocols do not report a shell hostname. Use the supplied numeric
    /// connection address; resolve a hostname only when it has one unique IP.
    public static func literal(_ host: String) -> String? {
        RemoteHostIdentity.address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }
    public static func resolve(_ profile: SessionProfile) -> String? {
        let host = profile.kind.usesSSH ? ((try? SSHIdentity.resolve(profile).host) ?? profile.host) : profile.host
        if let ip = literal(host) { return ip }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }
        var cursor = result, addresses = Set<String>()
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               let address = literal(String(cString: buffer)) { addresses.insert(address) }
        }
        return addresses.count == 1 ? addresses.first : nil
    }
}
