import AppKit
import CoreImage

enum QRCodeGenerator {
    static func makeImage(for text: String, pixelSize: CGFloat = 13) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Four modules of quiet zone are required for reliable scanning.
        let padded = output.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: CIColor.white).cropped(to: padded)
        let composed = output.composited(over: background)
        let scaled = composed.transformed(by: CGAffineTransform(scaleX: pixelSize, y: pixelSize))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
