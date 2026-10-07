// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

/// Leave the remote locale to the server. macOS's default SendEnv LANG LC_*
/// otherwise forwards locale names (notably LC_CTYPE=UTF-8) that Linux may lack.
public enum SSHEnvironment {
    public static func remoteClient(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { key, _ in
            key != "LANG" && key != "LANGUAGE" && !key.hasPrefix("LC_")
        }
    }
}
