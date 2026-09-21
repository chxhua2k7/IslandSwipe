// 設定頁圖示:黃色圓角底 + 白色 SF Symbol(和 DynamicNotLand 同風格)。
// 在 Mac 上用 AppKit 畫,輸出 bundle/ 的 29/58/87 和 logo/ 的 1024。
// 用法:swift logo/make_icon.swift
import AppKit

let symbolName = "hand.draw.fill"
let tint = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)   // #FFCC00
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(_ size: Int, to url: URL) {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    tint.setFill()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237).fill()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .medium)
    if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let white = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let g = white.size
        let scale = min(s * 0.62 / g.width, s * 0.62 / g.height)
        let w = g.width * scale, h = g.height * scale
        white.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

render(29, to: root.appendingPathComponent("bundle/IslandSwipe.png"))
render(58, to: root.appendingPathComponent("bundle/IslandSwipe@2x.png"))
render(87, to: root.appendingPathComponent("bundle/IslandSwipe@3x.png"))
render(1024, to: root.appendingPathComponent("logo/IslandSwipe-1024.png"))
print("done")
