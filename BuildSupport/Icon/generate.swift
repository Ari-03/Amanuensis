#!/usr/bin/env swift
import AppKit
import Foundation

// Run `swift BuildSupport/Icon/generate.swift` from any directory to rebuild the icon set.
// All shapes are drawn in a 1024-point canvas and rasterized separately at each size.
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let destination = repository.appendingPathComponent("Amanuensis/Assets.xcassets/AppIcon.appiconset")

struct IconEntry: Encodable {
    let filename: String
    let idiom = "mac"
    let scale: String
    let size: String
}

struct IconManifest: Encodable {
    struct Info: Encodable {
        let author = "xcode"
        let version = 1
    }
    let images: [IconEntry]
    let info = Info()
}

enum IconError: Error {
    case bitmapCreationFailed
    case imageEncodingFailed
    case gradientCreationFailed
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [NSColor]) throws -> NSGradient {
    guard let gradient = NSGradient(colors: colors) else { throw IconError.gradientCreationFailed }
    return gradient
}

func renderIcon(pixels: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw IconError.bitmapCreationFailed
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
        xRadius: 200, yRadius: 200)

    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0.025, 0.04, 0.15, alpha: 0.34)
    tileShadow.shadowBlurRadius = 28
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    color(0.15, 0.22, 0.62).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    try gradient([
        color(0.22, 0.17, 0.61),
        color(0.24, 0.29, 0.82),
        color(0.25, 0.51, 0.96),
    ]).draw(in: tile, angle: 65)

    // Soft light at the upper edge gives the tile depth without ornamenting the mark.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    try gradient([
        color(0.48, 0.81, 1, alpha: 0.31),
        color(0.40, 0.65, 1, alpha: 0),
    ]).draw(
        fromCenter: NSPoint(x: 235, y: 990), radius: 0,
        toCenter: NSPoint(x: 235, y: 990), radius: 850, options: [])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let rim = NSBezierPath(
        roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892),
        xRadius: 198, yRadius: 198)
    color(1, 1, 1, alpha: 0.15).setStroke()
    rim.lineWidth = 3
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let waveform = NSBezierPath()
    let heights: [CGFloat] = [170, 340, 510, 340, 170]
    for (offset, height) in heights.enumerated() {
        let bar = NSRect(
            x: 251 + CGFloat(offset) * 112, y: 526 - height / 2,
            width: 74, height: height)
        waveform.append(NSBezierPath(roundedRect: bar, xRadius: 37, yRadius: 37))
    }

    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow()
    markShadow.shadowColor = color(0.08, 0.08, 0.35, alpha: 0.28)
    markShadow.shadowBlurRadius = 18
    markShadow.shadowOffset = NSSize(width: 0, height: -9)
    markShadow.set()
    color(0.93, 0.96, 1).setFill()
    waveform.fill()
    NSGraphicsContext.restoreGraphicsState()

    try gradient([color(0.84, 0.91, 1), color(1, 1, 1)])
        .draw(in: waveform, angle: 90)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.imageEncodingFailed
    }
    return data
}

try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var entries: [IconEntry] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try renderIcon(pixels: size * scale).write(to: destination.appendingPathComponent(filename))
        entries.append(IconEntry(filename: filename, scale: "\(scale)x", size: "\(size)x\(size)"))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(IconManifest(images: entries))
    .write(to: destination.appendingPathComponent("Contents.json"))
print("Generated \(entries.count) icons in \(destination.path)")
