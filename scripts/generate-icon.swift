import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Original geometric artwork, with no manufacturer assets or SF Symbols.
// Run: swift scripts/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ?
                 CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 32,
                      color: CGColor(red: 0, green: 0.04, blue: 0.09, alpha: 0.35))
    context.setFillColor(CGColor(red: 0.045, green: 0.10, blue: 0.16, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 82, y: 82, width: 860, height: 860),
                           cornerWidth: 192, cornerHeight: 192, transform: nil))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setStrokeColor(CGColor(red: 0.15, green: 0.82, blue: 0.76, alpha: 1))
    context.setLineWidth(28)
    context.strokeEllipse(in: CGRect(x: 182, y: 184, width: 660, height: 660))
    for center in [CGFloat(358), CGFloat(666)] {
        context.setFillColor(CGColor(red: 0.89, green: 0.97, blue: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: center - 40, y: 296, width: 80, height: 255),
                               cornerWidth: 40, cornerHeight: 40, transform: nil))
        context.fillPath()
        context.fillEllipse(in: CGRect(x: center - 97, y: 494, width: 194, height: 216))
        context.setFillColor(CGColor(red: 0.08, green: 0.18, blue: 0.25, alpha: 1))
        context.fillEllipse(in: CGRect(x: center - 36, y: 562, width: 72, height: 80))
    }
    context.setFillColor(CGColor(red: 0.15, green: 0.82, blue: 0.76, alpha: 1))
    for index in 0..<3 {
        context.fill(CGRect(x: 474 + index * 30, y: 350, width: 16, height: 60 + index * 30))
    }
    let image = context.makeImage()!
    let url = output.appendingPathComponent("icon-\(size).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
