// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

extension WorkspaceController {
    @objc func showOpenSourceLicenses() {
        let alert = PopupAlert(); alert.messageText = "OShell 开源许可"
        alert.informativeText = "Copyright © 2026 OShell contributors.\n\nOShell 原创代码按 GNU GPL 第 3 版授权。你可以依照许可证使用、修改和再分发；本软件不提供任何担保。第三方组件保留各自的版权及许可条款。"
        alert.addButton(withTitle: "查看 GPL-3.0"); alert.addButton(withTitle: "第三方声明"); alert.addButton(withTitle: "关闭")
        let response = alert.runModal()
        let name: String
        switch response { case .alertFirstButtonReturn: name = "OShell-LICENSE"; case .alertSecondButtonReturn: name = "THIRD_PARTY_NOTICES"; default: return }
        if let url = Bundle.main.url(forResource: name, withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
}
