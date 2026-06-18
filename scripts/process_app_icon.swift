import AppKit
import CoreGraphics
import Foundation

struct Pixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    var brightness: UInt8 {
        max(r, max(g, b))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift scripts/process_app_icon.swift <source-png> <output-png>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let image = NSImage(contentsOf: sourceURL),
    let sourceCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fail("failed to load source image: \(sourceURL.path)")
}

let width = sourceCG.width
let height = sourceCG.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

guard
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let bitmap = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fail("failed to create bitmap context")
}

bitmap.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

func pixelAt(x: Int, y: Int) -> Pixel {
    let offset = y * bytesPerRow + x * bytesPerPixel
    return Pixel(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
}

let threshold: UInt8 = 18
let minimumRowCoverage = max(2, width / 80)
let minimumColumnCoverage = max(2, height / 80)

var minX = width
var minY = height
var maxX = 0
var maxY = 0

for y in 0..<height {
    var rowHits = 0
    for x in 0..<width where pixelAt(x: x, y: y).brightness > threshold {
        rowHits += 1
    }
    guard rowHits >= minimumRowCoverage else { continue }
    minY = min(minY, y)
    maxY = max(maxY, y)
}

for x in 0..<width {
    var columnHits = 0
    for y in 0..<height where pixelAt(x: x, y: y).brightness > threshold {
        columnHits += 1
    }
    guard columnHits >= minimumColumnCoverage else { continue }
    minX = min(minX, x)
    maxX = max(maxX, x)
}

guard minX < maxX, minY < maxY else {
    fail("failed to detect icon bounds")
}

let detected = CGRect(
    x: minX,
    y: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1
)
let side = min(CGFloat(min(width, height)), max(detected.width, detected.height) * 1.02)
let center = CGPoint(x: detected.midX, y: detected.midY)
let cropRect = CGRect(
    x: max(0, min(CGFloat(width) - side, center.x - side / 2)),
    y: max(0, min(CGFloat(height) - side, center.y - side / 2)),
    width: side,
    height: side
).integral

guard let cropped = sourceCG.cropping(to: cropRect) else {
    fail("failed to crop icon")
}

let outputSize = CGSize(width: 1024, height: 1024)
guard
    let outputRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(outputSize.width),
        pixelsHigh: Int(outputSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let graphicsContext = NSGraphicsContext(bitmapImageRep: outputRep)
else {
    fail("failed to create output bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
NSColor.clear.setFill()
NSRect(origin: .zero, size: outputSize).fill()

let iconRect = NSRect(origin: .zero, size: outputSize)
let mask = NSBezierPath(roundedRect: iconRect, xRadius: 218, yRadius: 218)
mask.addClip()

NSImage(cgImage: cropped, size: outputSize).draw(
    in: iconRect,
    from: NSRect(origin: .zero, size: outputSize),
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = outputRep.representation(using: .png, properties: [:]) else {
    fail("failed to encode output png")
}

try png.write(to: outputURL)
print(outputURL.path)
