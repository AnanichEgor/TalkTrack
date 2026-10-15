// Draws the TalkTrack application icon: a waveform like the menu-bar symbol,
// drawn here as plain rounded bars (SF Symbols may not be used in app icons),
// on a rounded-square background following the macOS icon grid.
//
//   swift scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // macOS grid: an 824 pt rounded square centered in 1024, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill(); shape.fill()
    context.restoreGState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.62, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // Waveform: symmetric rounded bars, tallest in the middle.
    let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.40, 0.92, 0.58, 0.80, 0.36, 0.18]
    let barWidth: CGFloat = 46, gap: CGFloat = 30, maxHeight: CGFloat = 520
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    NSColor.white.setFill()
    for (index, height) in heights.enumerated() {
        let h = max(barWidth, height * maxHeight)
        let x = 512 - total / 2 + CGFloat(index) * (barWidth + gap)
        NSBezierPath(roundedRect: NSRect(x: x, y: 512 - h / 2, width: barWidth, height: h),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
