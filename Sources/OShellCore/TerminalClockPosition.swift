// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

public enum TerminalClockPosition: String, Codable, CaseIterable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
    public var title: String {
        switch self {
        case .topLeft: return "左上角"
        case .topCenter: return "顶部居中"
        case .topRight: return "右上角"
        case .centerLeft: return "左侧居中"
        case .center: return "正中间"
        case .centerRight: return "右侧居中"
        case .bottomLeft: return "左下角"
        case .bottomCenter: return "底部居中"
        case .bottomRight: return "右下角"
        }
    }
    public var column: Int { Self.allCases.firstIndex(of: self)! % 3 }
    public var row: Int { Self.allCases.firstIndex(of: self)! / 3 }
}
