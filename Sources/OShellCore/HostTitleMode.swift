// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum HostTitleMode: String, Codable, CaseIterable {
    case activeProbe, passive, shellIntegration
    public var title: String {
        switch self {
        case .activeProbe: return "允许主动探测主机名/IP"
        case .passive: return "不主动探测，只展示主机名"
        case .shellIntegration: return "接受 Shell 集成上报"
        }
    }
    public var explanation: String {
        switch self {
        case .activeProbe: return "在空闲命令提示符处执行主机名/IP 探测，命令可能进入远端历史。收到 Shell 集成上报后停止主动探测。"
        case .passive: return "仅从提示符、OSC 标题和 OSC 7 目录识别主机名，不执行探测命令，也不采用 Shell 集成的主机信息上报。"
        case .shellIntegration: return "优先采用 Shell 集成上报的主机名/IP；未安装脚本时退回提示符、OSC 标题和目录识别，不执行探测命令。"
        }
    }
}
