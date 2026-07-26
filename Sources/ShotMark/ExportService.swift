import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportServiceError: LocalizedError {
    case bitmapContextFailed
    case imageEncodingFailed(format: String)
    case imageDecodingFailed
    case clipboardFailed

    var errorDescription: String? {
        switch self {
        case .bitmapContextFailed:
            return "无法创建图片渲染上下文。"
        case .imageEncodingFailed(let format):
            return "\(format) 编码失败。"
        case .imageDecodingFailed:
            return "无法读取图片数据。"
        case .clipboardFailed:
            return "写入剪切板失败。"
        }
    }
}

final class ExportService {
    static func defaultSaveURL(createdAt: Date) -> URL {
        uniqueURL(prefix: "Screenshot", createdAt: createdAt, fileExtension: "png")
    }

    static func defaultRecordingURL(createdAt: Date) -> URL {
        uniqueURL(prefix: "Recording", createdAt: createdAt, fileExtension: "mp4")
    }

    static func defaultLongScreenshotURL(createdAt: Date) -> URL {
        uniqueURL(prefix: "Long Screenshot", createdAt: createdAt, fileExtension: "png")
    }

    static func saveConfirmation(for url: URL) -> String {
        "已保存到 \(url.deletingLastPathComponent().lastPathComponent)"
    }

    private static func uniqueURL(
        prefix: String,
        createdAt: Date,
        fileExtension: String
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "\(prefix) \(formatter.string(from: createdAt))"
        let directory = AppSettings.defaultSaveDirectory
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    func export(state: EditorState, to destination: ExportDestination) throws {
        try exportPNGData(pngData(for: state), to: destination)
    }

    func exportPNGData(_ data: Data, to destination: ExportDestination) throws {
        switch destination {
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else {
                throw ExportServiceError.clipboardFailed
            }
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    func pngData(for state: EditorState) throws -> Data {
        let bitmap = try renderedBitmap(for: state)
        return try encodedPNGData(bitmap: bitmap)
    }

    private func renderedBitmap(for state: EditorState) throws -> NSBitmapImageRep {
        let image = state.capture.image
        let pointSize = state.capture.imagePointSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width,
            pixelsHigh: image.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ExportServiceError.bitmapContextFailed
        }
        rep.size = pointSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ExportServiceError.bitmapContextFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor.clear.setFill()
        CGRect(origin: .zero, size: pointSize).fill()

        let nsImage = NSImage(cgImage: image, size: pointSize)
        nsImage.draw(in: CGRect(origin: .zero, size: pointSize))
        applyMosaicAnnotations(state.annotations, to: image, pointSize: pointSize)
        AnnotationDrawing.draw(state.annotations.filter { !$0.isMosaic }, in: pointSize)

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    private func encodedPNGData(bitmap: NSBitmapImageRep) throws -> Data {
        guard let image = bitmap.cgImage else {
            throw ExportServiceError.imageEncodingFailed(format: "PNG")
        }
        let horizontalDPI = bitmap.size.width > 0
            ? CGFloat(bitmap.pixelsWide) / bitmap.size.width * 72
            : 72
        let verticalDPI = bitmap.size.height > 0
            ? CGFloat(bitmap.pixelsHigh) / bitmap.size.height * 72
            : 72
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportServiceError.imageEncodingFailed(format: "PNG")
        }

        let dpi = min(horizontalDPI, verticalDPI)
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportServiceError.imageEncodingFailed(format: "PNG")
        }
        return data as Data
    }

    private func applyMosaicAnnotations(_ annotations: [Annotation], to image: CGImage, pointSize: CGSize) {
        for annotation in annotations {
            guard case .mosaic(let rect, let blockSize) = annotation else { continue }
            applyMosaic(rect: rect, blockSize: blockSize, sourceImage: image, pointSize: pointSize)
        }
    }

    private func applyMosaic(rect: CGRect, blockSize: CGFloat, sourceImage: CGImage, pointSize: CGSize) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: pointSize))
        guard clipped.width > 1, clipped.height > 1 else { return }

        MosaicRenderer.drawFrostedMosaic(
            rect: clipped,
            blockSize: blockSize,
            sourceImage: sourceImage,
            pointSize: pointSize
        )
    }
}
