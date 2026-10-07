// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum QuickSendScope: Int, Codable, CaseIterable {
    case current = 0, tab = 1, all = 2, visible = 3, selected = 4
    public var title: String {
        switch self {
        case .current: return "当前会话"
        case .tab: return "当前标签内的分屏"
        case .all: return "全部会话（本窗口）"
        case .visible: return "可见会话"
        case .selected: return "手动选择会话…"
        }
    }
}
