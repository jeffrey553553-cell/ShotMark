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

struct ExportImagePayload {
    let pngData: Data
    let fileData: Data
    let fileFormat: ImageExportFormat
}

final class ExportService {
    static func defaultSaveURL(createdAt: Date) -> URL {
        configuredURL(
            createdAt: createdAt,
            kind: .screenshot,
            fileExtension: AppSettings.shared.imageExportFormat.fileExtension
        )
    }

    static func defaultRecordingURL(createdAt: Date) -> URL {
        configuredURL(createdAt: createdAt, kind: .recording, fileExtension: "mp4")
    }

    static func defaultLongScreenshotURL(createdAt: Date) -> URL {
        configuredURL(
            createdAt: createdAt,
            kind: .longScreenshot,
            fileExtension: AppSettings.shared.imageExportFormat.fileExtension
        )
    }

    static func saveConfirmation(for url: URL) -> String {
        "已保存到 \(url.deletingLastPathComponent().lastPathComponent)"
    }

    private static func configuredURL(
        createdAt: Date,
        kind: ExportMediaKind,
        fileExtension: String
    ) -> URL {
        ExportNaming.uniqueURL(
            directory: AppSettings.shared.saveDirectory,
            template: AppSettings.shared.filenameTemplate,
            kind: kind,
            createdAt: createdAt,
            fileExtension: fileExtension
        )
    }

    func export(state: EditorState, to destination: ExportDestination) throws {
        switch destination {
        case .clipboard:
            try exportPNGData(pngData(for: state), to: destination)
        case .file:
            let payload = try imagePayload(for: state)
            try exportImageData(
                payload.fileData,
                format: payload.fileFormat,
                to: destination
            )
        }
    }

    func exportPNGData(_ data: Data, to destination: ExportDestination) throws {
        try exportImageData(data, format: .png, to: destination)
    }

    func exportImageData(
        _ data: Data,
        format: ImageExportFormat,
        to destination: ExportDestination
    ) throws {
        switch destination {
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let pasteboardType = NSPasteboard.PasteboardType(format.uniformType.identifier)
            guard pasteboard.setData(data, forType: pasteboardType) else {
                throw ExportServiceError.clipboardFailed
            }
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    func pngData(for state: EditorState) throws -> Data {
        let bitmap = try renderedBitmap(for: state)
        return try encodedData(bitmap: bitmap, format: .png, quality: 1)
    }

    func imagePayload(
        for state: EditorState,
        format: ImageExportFormat = AppSettings.shared.imageExportFormat,
        quality: Double = AppSettings.shared.imageExportQuality
    ) throws -> ExportImagePayload {
        let bitmap = try renderedBitmap(for: state)
        let pngData = try encodedData(bitmap: bitmap, format: .png, quality: 1)
        let fileData = format == .png
            ? pngData
            : try encodedData(bitmap: bitmap, format: format, quality: quality)
        return ExportImagePayload(
            pngData: pngData,
            fileData: fileData,
            fileFormat: format
        )
    }

    func transcodePNGData(
        _ pngData: Data,
        to format: ImageExportFormat = AppSettings.shared.imageExportFormat,
        quality: Double = AppSettings.shared.imageExportQuality
    ) throws -> Data {
        guard format != .png else { return pngData }
        guard
            let source = CGImageSourceCreateWithData(pngData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ExportServiceError.imageDecodingFailed
        }
        return try encodedData(
            image: image,
            format: format,
            quality: quality,
            dpi: 72
        )
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

    private func encodedData(
        bitmap: NSBitmapImageRep,
        format: ImageExportFormat,
        quality: Double
    ) throws -> Data {
        guard let image = bitmap.cgImage else {
            throw ExportServiceError.imageEncodingFailed(format: format.title)
        }
        let horizontalDPI = bitmap.size.width > 0
            ? CGFloat(bitmap.pixelsWide) / bitmap.size.width * 72
            : 72
        let verticalDPI = bitmap.size.height > 0
            ? CGFloat(bitmap.pixelsHigh) / bitmap.size.height * 72
            : 72
        return try encodedData(
            image: image,
            format: format,
            quality: quality,
            dpi: min(horizontalDPI, verticalDPI)
        )
    }

    private func encodedData(
        image: CGImage,
        format: ImageExportFormat,
        quality: Double,
        dpi: CGFloat
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.uniformType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportServiceError.imageEncodingFailed(format: format.title)
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        if format.supportsQualityAdjustment {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.3, quality))
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportServiceError.imageEncodingFailed(format: format.title)
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
