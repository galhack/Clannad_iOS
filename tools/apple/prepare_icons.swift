#!/usr/bin/env swift
// Package the approved square feather artwork for Apple asset catalogs.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("app/Artwork/FeatherSquare.png")
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
      image.width >= 1024, image.width == image.height else {
    fatalError("Expected a square feather source of at least 1024 pixels")
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func context(opaque: Bool) -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    return CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                     bytesPerRow: 4096, space: space, bitmapInfo: alpha.rawValue)!
}
func write(_ image: CGImage, to relativePath: String) {
    let url = root.appendingPathComponent(relativePath)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create icon: \(relativePath)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon: \(relativePath)") }
}
let canvas = context(opaque: true)
// Render an opaque 1024-pixel rendition; platform masks shape the icon.
canvas.setFillColor(CGColor(red: 0.13, green: 0.58, blue: 0.97, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
canvas.interpolationQuality = .high
canvas.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let opaque = canvas.makeImage()!
let assets = "app/Resources/Assets.xcassets/"
write(opaque, to: assets + "AppIcon.appiconset/AppIcon.png")
write(opaque, to: "engine/siglus_rs/icon/Icon.png")
let vision = assets + "AppIconVision.solidimagestack/"
write(opaque, to: vision + "Back.solidimagestacklayer/Content.imageset/back.png")
// Keep the same composition on visionOS. Empty overlay planes
// satisfy the existing layered asset layout without adding new artwork.
let clear = context(opaque: false)
clear.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
for (layer, name) in [("Middle", "middle"), ("Front", "front")] {
    write(clear.makeImage()!, to: vision + "\(layer).solidimagestacklayer/Content.imageset/\(name).png")
}
print("Prepared unified feather icons (1024 x 1024, opaque app/background images)")
