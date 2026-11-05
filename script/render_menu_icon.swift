// Independent geometric drawing, not a traced app-icon silhouette.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
for scale in [1, 2] {
    let pixels = 18 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(NSColor.black.cgColor)
    context.fillEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
    context.setBlendMode(.clear)
    context.setLineWidth(1.1)
    context.strokeEllipse(in: CGRect(x: 3.2, y: 3.2, width: 11.6, height: 11.6))
    context.fillEllipse(in: CGRect(x: 9.3, y: 9.3, width: 9.4, height: 9.4))
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon-18@\(scale)x.png"))
}
