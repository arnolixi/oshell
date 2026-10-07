// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

// Approved OShell brand: graphite + flame-orange O-shaped multi-session terminal.
// Generate the iconset for both modern and legacy builds from this single source.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func stroke(_ points: [NSPoint], width: CGFloat, tint: NSColor) {
    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; tint.setStroke(); path.stroke()
}
func renderIcon(_ pixels: Int, light: Bool) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(pixels) / 1024); scale.concat()
    let tile = rounded(104, 104, 816, 816, 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x121A26, alpha: 0.22)
    shadow.shadowBlurRadius = 24 * CGFloat(pixels) / 1024; shadow.shadowOffset = NSSize(width: 0, height: -14 * CGFloat(pixels) / 1024); shadow.set()
    color(light ? 0xDADEE4 : 0x20252D).setFill(); tile.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(light ? 0xFCFCFD : 0x343C47), ending: color(light ? 0xDCE1E7 : 0x151B23))!.draw(in: tile, angle: -75)
    if pixels >= 64 { color(0xFFFFFF, alpha: light ? 0.8 : 0.14).setStroke(); tile.lineWidth = 3; tile.stroke() }
    // Two offset sessions behind the active terminal. The O remains the hero.
    for (x, y, tint) in [(CGFloat(296), CGFloat(290), light ? UInt32(0xBDC5CF) : 0x556171), (258, 252, light ? UInt32(0x8F9AA8) : 0x8894A4)] {
        let frame = rounded(x, y, 530, 548, 180)
        color(tint).setFill(); frame.fill()
        color(light ? 0xE9ECF0 : 0x242C36).setFill(); rounded(x + 25, y + 25, 480, 498, 155).fill()
    }
    let shell = rounded(212, 194, 560, 588, 192)
    NSGradient(starting: color(0xFF9B56), ending: color(0xF14A3D))!.draw(in: shell, angle: -75)
    let screen = rounded(273, 255, 438, 466, 132)
    NSGradient(starting: color(0x252D39), ending: color(0x101720))!.draw(in: screen, angle: -90)
    // Active tab inset. Retain simple main silhouette at small icon sizes.
    color(0xFF8550).setFill(); rounded(335, 677, 112, 13, 6.5).fill()
    color(0x788492, alpha: 0.7).setFill(); rounded(465, 677, 70, 13, 6.5).fill(); rounded(553, 677, 70, 13, 6.5).fill()
    stroke([NSPoint(x: 352, y: 588), NSPoint(x: 448, y: 498), NSPoint(x: 352, y: 408)], width: 48, tint: color(0xF7F8FA))
    stroke([NSPoint(x: 514, y: 409), NSPoint(x: 622, y: 409)], width: 48, tint: color(0xFF8550))
    NSGraphicsContext.restoreGraphicsState(); return image
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let bitmap = renderIcon(points * scale, light: false)
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
if CommandLine.arguments.count > 2 {
    let brand = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    try renderIcon(1024, light: false).representation(using: .png, properties: [:])!.write(to: brand.appendingPathComponent("OShell-icon.png"))
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <title>OShell — O-shaped multi-session terminal, graphite and flame-orange</title>
    <defs>
    <linearGradient id="tile" x2=".3" y2="1"><stop stop-color="#343C47"/><stop offset="1" stop-color="#151B23"/></linearGradient>
    <linearGradient id="rim" x2=".3" y2="1"><stop stop-color="#FF9B56"/><stop offset="1" stop-color="#F14A3D"/></linearGradient>
    <linearGradient id="screen" x2="0" y2="1"><stop stop-color="#252D39"/><stop offset="1" stop-color="#101720"/></linearGradient>
    </defs>
    <rect x="104" y="104" width="816" height="816" rx="184" fill="url(#tile)"/>
    <rect x="296" y="186" width="530" height="548" rx="180" fill="#556171"/>
    <rect x="321" y="211" width="480" height="498" rx="155" fill="#242C36"/>
    <rect x="258" y="224" width="530" height="548" rx="180" fill="#8894A4"/>
    <rect x="283" y="249" width="480" height="498" rx="155" fill="#242C36"/>
    <rect x="212" y="242" width="560" height="588" rx="192" fill="url(#rim)"/>
    <rect x="273" y="303" width="438" height="466" rx="132" fill="url(#screen)"/>
    <rect x="335" y="334" width="112" height="13" rx="6.5" fill="#FF8550"/>
    <path d="M471.5 340.5h57 M559.5 340.5h57" stroke="#788492" stroke-opacity=".7" stroke-width="13" stroke-linecap="round"/>
    <path d="M352 436 L448 526 L352 616" stroke="#F7F8FA" stroke-width="48" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
    <path d="M514 615 H622" stroke="#FF8550" stroke-width="48" stroke-linecap="round"/>
    </svg>
    """
    try Data(svg.utf8).write(to: brand.appendingPathComponent("OShell-icon.svg"))
    let mark = """
    <svg xmlns="http://www.w3.org/2000/svg" width="704" height="744" viewBox="160 132 704 744">
    <title>OShell — standalone multi-session terminal mark</title>
    <defs>
    <linearGradient id="tile" x2=".3" y2="1"><stop stop-color="#343C47"/><stop offset="1" stop-color="#151B23"/></linearGradient>
    <linearGradient id="rim" x2=".3" y2="1"><stop stop-color="#FF9B56"/><stop offset="1" stop-color="#F14A3D"/></linearGradient>
    <linearGradient id="screen" x2="0" y2="1"><stop stop-color="#252D39"/><stop offset="1" stop-color="#101720"/></linearGradient>
    </defs>
    
    <rect x="296" y="186" width="530" height="548" rx="180" fill="#556171"/>
    <rect x="321" y="211" width="480" height="498" rx="155" fill="#242C36"/>
    <rect x="258" y="224" width="530" height="548" rx="180" fill="#8894A4"/>
    <rect x="283" y="249" width="480" height="498" rx="155" fill="#242C36"/>
    <rect x="212" y="242" width="560" height="588" rx="192" fill="url(#rim)"/>
    <rect x="273" y="303" width="438" height="466" rx="132" fill="url(#screen)"/>
    <rect x="335" y="334" width="112" height="13" rx="6.5" fill="#FF8550"/>
    <path d="M471.5 340.5h57 M559.5 340.5h57" stroke="#788492" stroke-opacity=".7" stroke-width="13" stroke-linecap="round"/>
    <path d="M352 436 L448 526 L352 616" stroke="#F7F8FA" stroke-width="48" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
    <path d="M514 615 H622" stroke="#FF8550" stroke-width="48" stroke-linecap="round"/>
    </svg>
    """
    try Data(mark.utf8).write(to: brand.appendingPathComponent("OShell-mark.svg"))
    func drawIcon(_ size: Int, rect: NSRect) {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(renderIcon(size, light: false))
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, tint: UInt32) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color(tint)])
    }
    for compact in [false, true] {
        let width = compact ? 800 : 900, height = compact ? 420 : 540
        let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
        for dark in [false, true] {
            let x: CGFloat = compact ? 0 : (dark ? 450 : 0)
            let y: CGFloat = compact && !dark ? 210 : 0
            color(dark ? 0x171C24 : 0xEDF0F3).setFill()
            NSRect(x: x, y: y, width: compact ? 800 : 450, height: compact ? 210 : 540).fill()
            let ink: UInt32 = dark ? 0xECF0F4 : 0x26313E
            if compact {
                text(dark ? "深色背景" : "浅色背景", x: 26, y: y + 166, size: 16, tint: ink)
                for (index, size) in [16, 32, 64, 128].enumerated() {
                    let center = CGFloat(100 + index * 186)
                    drawIcon(size, rect: NSRect(x: center - CGFloat(size) / 2, y: y + 82 - CGFloat(size) / 2, width: CGFloat(size), height: CGFloat(size)))
                    text("\(size) pt", x: center - 20, y: y + 10, size: 12, tint: ink)
                }
            } else {
                text("OShell", x: x + 40, y: 464, size: 32, tint: ink)
                text("石墨 · 焰橙", x: x + 40, y: 427, size: 20, tint: dark ? 0xFF9860 : 0xAC452C)
                drawIcon(512, rect: NSRect(x: x + 33, y: 40, width: 384, height: 384))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try preview.representation(using: .png, properties: [:])!.write(to: brand.appendingPathComponent(compact ? "Size-review.png" : "Preview.png"))
    }
}
