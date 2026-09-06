// Renders the app icon into an .iconset directory from an SF Symbol.
// Usage: make-icon <output.iconset>

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func render(_ pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded-rect ground, in the proportions macOS icons use.
    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.36, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.29, blue: 0.93, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(config) {
        let white = tinted(configured, .white)
        let s = white.size
        let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
        white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 0.95)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let data = render(pixels) else {
            FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
            exit(1)
        }
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
print("wrote iconset to \(outDir.path)")
