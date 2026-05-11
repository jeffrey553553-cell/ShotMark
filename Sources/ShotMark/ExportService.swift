import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ExportServiceError: LocalizedError {
    case bitmapContextFailed
    case pngEncodingFailed
    case clipboardFailed

    var errorDescription: String? {
        switch self {
        case .bitmapContextFailed:
            return "无法创建图片渲染上下文。"
        case .pngEncodingFailed:
            return "PNG 编码失败。"
        case .clipboardFailed:
            return "写入剪切板失败。"
        }
    }
}

final class ExportService {
    static func defaultSaveURL(createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "Screenshot \(formatter.string(from: createdAt)).png"
        return AppSettings.shared.saveDirectory.appendingPathComponent(filename)
    }

    static func defaultRecordingURL(createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "Recording \(formatter.string(from: createdAt)).mp4"
        return AppSettings.shared.saveDirectory.appendingPathComponent(filename)
    }

    static func defaultLongScreenshotURL(createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "Long Screenshot \(formatter.string(from: createdAt)).png"
        return AppSettings.shared.saveDirectory.appendingPathComponent(filename)
    }

    func export(state: EditorState, to destination: ExportDestination) throws {
        let data = try pngData(for: state)
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

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ExportServiceError.pngEncodingFailed
        }
        return data
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
