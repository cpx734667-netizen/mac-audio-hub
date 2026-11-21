import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/airmic-icon.png"
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create drawing context")
}

let inset: CGFloat = 54
let iconRect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let corner: CGFloat = 218

// Soft shadow around the rounded icon tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
let tilePath = CGPath(roundedRect: iconRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
context.addPath(tilePath)
context.setFillColor(CGColor(red: 0.05, green: 0.12, blue: 0.14, alpha: 1))
context.fillPath()
context.restoreGState()

// Main gradient.
context.saveGState()
context.addPath(tilePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.55, green: 0.98, blue: 0.89, alpha: 1),
        CGColor(red: 0.22, green: 0.86, blue: 0.77, alpha: 1),
        CGColor(red: 0.43, green: 0.49, blue: 0.97, alpha: 1)
    ] as CFArray,
    locations: [0.0, 0.52, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 170, y: 950),
    end: CGPoint(x: 920, y: 80),
    options: []
)

// Warm highlight in the upper-left corner.
let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.32),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: 320, y: 860),
    startRadius: 0,
    endCenter: CGPoint(x: 320, y: 860),
    endRadius: 430,
    options: []
)

// Subtle depth at the bottom.
let bottomShade = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.03, green: 0.08, blue: 0.12, alpha: 0),
        CGColor(red: 0.03, green: 0.08, blue: 0.12, alpha: 0.19)
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    bottomShade,
    start: CGPoint(x: 512, y: 500),
    end: CGPoint(x: 512, y: 54),
    options: []
)
context.restoreGState()

// Inner rim light.
context.saveGState()
context.addPath(CGPath(
    roundedRect: iconRect.insetBy(dx: 3, dy: 3),
    cornerWidth: corner - 3,
    cornerHeight: corner - 3,
    transform: nil
))
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

let ink = CGColor(red: 0.018, green: 0.075, blue: 0.070, alpha: 1)

// Microphone body.
let bodyRect = CGRect(x: 432, y: 346, width: 160, height: 324)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(red: 0, green: 0.15, blue: 0.12, alpha: 0.28))
context.addPath(CGPath(roundedRect: bodyRect, cornerWidth: 80, cornerHeight: 80, transform: nil))
context.setFillColor(ink)
context.fillPath()
context.restoreGState()

// Grille lines.
context.setStrokeColor(CGColor(red: 0.36, green: 0.92, blue: 0.82, alpha: 0.44))
context.setLineWidth(5)
context.setLineCap(.round)
for y in [548.0, 586.0, 624.0] {
    context.move(to: CGPoint(x: 472, y: y))
    context.addLine(to: CGPoint(x: 552, y: y))
}
context.strokePath()

// Cradle arc.
context.setStrokeColor(ink)
context.setLineWidth(38)
context.setLineCap(.round)
context.move(to: CGPoint(x: 338, y: 518))
context.addCurve(
    to: CGPoint(x: 686, y: 518),
    control1: CGPoint(x: 354, y: 300),
    control2: CGPoint(x: 670, y: 300)
)
context.strokePath()

// Stem and base.
context.setLineWidth(34)
context.move(to: CGPoint(x: 512, y: 310))
context.addLine(to: CGPoint(x: 512, y: 244))
context.strokePath()
context.move(to: CGPoint(x: 432, y: 232))
context.addLine(to: CGPoint(x: 592, y: 232))
context.strokePath()

// Small light reflection on the body.
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
context.setLineWidth(9)
context.move(to: CGPoint(x: 456, y: 590))
context.addLine(to: CGPoint(x: 456, y: 618))
context.strokePath()

guard let image = context.makeImage() else { fatalError("Could not create image") }
let url = URL(fileURLWithPath: output)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create image destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write PNG") }
print("Wrote \(output)")
