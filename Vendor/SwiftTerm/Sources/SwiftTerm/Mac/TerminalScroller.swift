// OShell adaptation: a standalone terminal has no NSScrollView to manage
// overlay-scroller visibility. Keep native dragging/accessibility and own
// only the transient presentation and terminal-palette drawing.
#if os(macOS)
import AppKit

final class TerminalScroller: NSScroller {
    static let overlayWidth: CGFloat = 12
    private var presentationStyle: NSScroller.Style = .overlay
    private var foreground = NSColor.textColor
    private var background = NSColor.textBackgroundColor
    private var hideTimer: Timer?
    private var tracking = false
    private var visible = false
    private var generation = 0

    override var isOpaque: Bool { false }

    func applyColors(foreground: NSColor, background: NSColor) {
        self.foreground = foreground; self.background = background
        needsDisplay = true
    }
    func applyStyle(_ style: NSScroller.Style) {
        presentationStyle = style
        // Standalone native overlay scrollers keep a private knob-fade state
        // normally driven by NSScrollView. Use stable native tracking metrics;
        // our drawing/alpha supplies the overlay without competing fade states.
        scrollerStyle = .legacy
        hideImmediately()
    }
    func scrollingActivity() {
        guard presentationStyle == .overlay, isEnabled, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        generation += 1; hideTimer?.invalidate(); hideTimer = nil
        layer?.removeAllAnimations(); alphaValue = 1; visible = true; needsDisplay = true
        guard !tracking else { return }
        let token = generation
        let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self, self.generation == token, !self.tracking else { return }
            self.hideTimer = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == token else { return }
                self.visible = false
            })
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func hideImmediately() {
        generation += 1; hideTimer?.invalidate(); hideTimer = nil
        layer?.removeAllAnimations(); visible = presentationStyle == .legacy
        alphaValue = visible ? 1 : 0
    }
    override func draw(_ dirtyRect: NSRect) {
        // A transparent overlay track exposes the terminal background and
        // preserves the last column. Only explicit legacy mode reserves space.
        if presentationStyle == .legacy { background.setFill(); bounds.fill() }
        drawKnob()
    }
    override func drawKnob() {
        guard isEnabled else { return }
        let native = rect(for: .knob)
        guard native.height > 0 else { return }
        // Keep every painted pixel inside the native knob's drag hit area,
        // including the narrower overlay frame on older AppKit versions.
        let right = min(bounds.maxX - 2, native.maxX)
        let knob = NSRect(x: right - 4, y: native.minY, width: 4, height: native.height)
        foreground.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2).fill()
    }
    override func trackKnob(with event: NSEvent) {
        tracking = true; scrollingActivity()
        defer { tracking = false; scrollingActivity() }
        super.trackKnob(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visible, isEnabled else { return nil }
        return super.hitTest(point)
    }
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideImmediately() }
    }
    override func viewDidHide() { super.viewDidHide(); hideImmediately() }
    deinit { hideTimer?.invalidate() }
}
#endif
