// SPDX-License-Identifier: GPL-3.0-or-later
// Rasterize the existing PLANK logo into visionOS's two-layer app icon.
import AppKit

guard CommandLine.arguments.count == 3,
      let logo = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Expected PLANK logo and generated asset directory")
}

let assets = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for layer in ["Front", "Back"] {
    let transparent = layer == "Front"
    guard let bitmap = CGContext(data: nil, width: 1024, height: 1024,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                 bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast
                                                           : CGImageAlphaInfo.noneSkipLast).rawValue) else {
        fatalError("Could not create icon bitmap")
    }
    if transparent {
        bitmap.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        logo.draw(in: NSRect(x: 50, y: 68, width: 924, height: 878),
                  from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    } else {
        bitmap.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.05, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    guard let image = bitmap.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Could not export icon layer")
    }
    let destination = assets.appendingPathComponent(
        "AppIcon.solidimagestack/\(layer).solidimagestacklayer/Content.imageset/\(layer.lowercased()).png")
    try png.write(to: destination, options: .atomic)
}
