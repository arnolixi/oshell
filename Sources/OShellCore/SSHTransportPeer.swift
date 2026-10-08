// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

/// Observed local TCP peer, not a DNS guess or the identity of a nested host.
public struct SSHTransportPeer: Equatable, Hashable {
    public let address: String
    public let port: Int
    public init(address: String, port: Int) { self.address = address; self.port = port }

    /// Bounded, read-only snapshot of the SSH process and its proxy/helper children.
    /// Ambiguous connections are left unknown rather than choosing a tunnel socket.
    public static func observe(process pid: pid_t) -> SSHTransportPeer? {
        guard pid > 0 else { return nil }
        var queue: [(pid_t, Int)] = [(pid, 0)], visited = Set<pid_t>(), peers = Set<SSHTransportPeer>()
        while !queue.isEmpty && visited.count < 32 {
            let (process, depth) = queue.removeFirst()
            guard visited.insert(process).inserted else { continue }
            let size = proc_pidinfo(process, PROC_PIDLISTFDS, 0, nil, 0)
            if size > 0 && size <= 4096 * MemoryLayout<proc_fdinfo>.stride {
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
                let capacity = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
                let count = descriptors.withUnsafeMutableBytes { proc_pidinfo(process, PROC_PIDLISTFDS, 0, $0.baseAddress, capacity) }
                for descriptor in descriptors.prefix(max(0, Int(count) / MemoryLayout<proc_fdinfo>.stride)) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                    var info = socket_fdinfo()
                    guard proc_pidfdinfo(process, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) == MemoryLayout<socket_fdinfo>.size,
                          info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
                    var socket = info.psi.soi_proto.pri_tcp.tcpsi_ini
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    let address: String?
                    if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
                        address = inet_ntop(AF_INET, &socket.insi_faddr.ina_46.i46a_addr4, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
                    } else {
                        address = inet_ntop(AF_INET6, &socket.insi_faddr.ina_6, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
                    }
                    if let address { peers.insert(Self(address: address, port: Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_fport))))) }
                }
            }
            if depth < 3 {
                var children = [pid_t](repeating: 0, count: 32)
                let count = children.withUnsafeMutableBytes { proc_listchildpids(process, $0.baseAddress, Int32($0.count)) }
                queue += children.prefix(max(0, Int(count) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }.map { ($0, depth + 1) }
            }
        }
        return peers.count == 1 ? peers.first : nil
    }
}
