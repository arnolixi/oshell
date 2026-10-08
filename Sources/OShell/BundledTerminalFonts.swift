// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import CoreText
import Foundation

/// Register once for this process only; never install into the user's font library.
enum BundledTerminalFonts {
    private static let registration: Void = {
        for name in ["DejaVuSansMono", "DejaVuSansMono-Bold", "DejaVuSansMono-Oblique", "DejaVuSansMono-BoldOblique"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "DejaVuFonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func register() { _ = registration }
}
