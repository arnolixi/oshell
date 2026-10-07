#if os(macOS)
import AppKit

extension NSColor {
    static var swiftTermAccentColor: NSColor {
        if #available(macOS 10.14, *) { return .controlAccentColor }
        return .selectedControlColor
    }
}

extension NSImage {
    convenience init?(swiftTermSymbolName name: String, accessibilityDescription: String?) {
        if #available(macOS 11, *) { self.init(systemSymbolName: name, accessibilityDescription: accessibilityDescription) }
        else {
            let image = NSImage(size: NSSize(width: 14, height: 14))
            image.lockFocus()
            let text = name.contains("up") ? "↑" : name.contains("down") ? "↓" : "×"
            (text as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            guard let data = image.tiffRepresentation else { return nil }
            self.init(data: data)
        }
    }
}
#if OSHELL_LEGACY
extension TerminalView {
    var useMetalRenderer: Bool { false }
    var metalView: NSView? { nil }
    func queueMetalDisplay() { needsDisplay = true }
}
public extension TerminalView {
    var isUsingMetalRenderer: Bool { false }
    var metalRendererStatus: MetalRendererStatus { MetalRendererStatus(state: .disabled, presentedFrameCount: 0, lastFramePresentedAt: nil) }
    func setUseMetal(_ enabled: Bool) throws { /* Legacy builds use CoreGraphics. */ }
}
#endif
#endif
