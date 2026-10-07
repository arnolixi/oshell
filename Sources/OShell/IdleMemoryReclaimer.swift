// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import SwiftTerm

/// Large scrollback allocations can be freed while malloc keeps their pages.
/// Reclaim only after the last tab closes, off the UI queue and after teardown.
final class IdleMemoryReclaimer {
    private var pending: DispatchWorkItem?
    private(set) var completedPasses = 0
    private(set) var releasedBytes = 0
    private(set) var lastDurationMilliseconds = 0.0

    func cancel() { pending?.cancel(); pending = nil }

    func schedule(isIdle: @escaping () -> Bool) {
        cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isIdle() else { return }
            self.pending = nil
            // Drain Objective-C cache entries before asking malloc to return pages.
            autoreleasepool { TerminalView.releaseSharedRenderCaches() }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let started = DispatchTime.now().uptimeNanoseconds
                let bytes = malloc_zone_pressure_relief(nil, 0)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.completedPasses += 1; self.releasedBytes += bytes
                    self.lastDurationMilliseconds = elapsed
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    deinit { cancel() }
}
