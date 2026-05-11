import AppKit
import CoreGraphics
import Foundation

struct CaptureSelection {
    let rectInScreen: CGRect
    let screen: NSScreen
}

enum CaptureCommitAction {
    case copyToClipboard
    case saveToFile
    case pinToScreen
    case recordVideo(quality: VideoQualityPreset, audioMode: VideoAudioMode)
    case longScreenshot
}

enum VideoAudioMode: String, CaseIterable {
    case none
    case system
    case microphone
    case systemAndMicrophone

    var title: String {
        switch self {
        case .none: "无声"
        case .system: "系统音"
        case .microphone: "麦克风"
        case .systemAndMicrophone: "系统+麦克风"
        }
    }

    var capturesSystemAudio: Bool {
        self == .system || self == .systemAndMicrophone
    }

    var capturesMicrophone: Bool {
        self == .microphone || self == .systemAndMicrophone
    }

    var requiresMicrophonePermission: Bool {
        capturesMicrophone
    }
}

enum VideoQualityPreset: String, CaseIterable {
    case native
    case p720
    case p1080
    case p2k

    var title: String {
        switch self {
        case .native: "原生"
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2k: "2K"
        }
    }

    var maxLongEdge: CGFloat? {
        switch self {
        case .native: nil
        case .p720: 1280
        case .p1080: 1920
        case .p2k: 2560
        }
    }

    func outputPixelSize(for selection: CaptureSelection) -> CGSize {
        let nativeSize = CGSize(
            width: selection.rectInScreen.width * selection.screen.backingScaleFactor,
            height: selection.rectInScreen.height * selection.screen.backingScaleFactor
        )
        guard let maxLongEdge else {
            return nativeSize.evenPixelSize
        }

        let longEdge = max(nativeSize.width, nativeSize.height)
        let scale = longEdge > 0 ? min(1, maxLongEdge / longEdge) : 1
        return CGSize(width: nativeSize.width * scale, height: nativeSize.height * scale).evenPixelSize
    }
}

enum RecordingUIState {
    case idle
    case starting
    case recording(startedAt: Date)
    case stopping
}

struct CaptureResult {
    let image: CGImage
    let selectionRectInScreen: CGRect
    let screenScale: CGFloat
    let createdAt: Date

    var imagePointSize: CGSize {
        CGSize(width: CGFloat(image.width) / screenScale, height: CGFloat(image.height) / screenScale)
    }
}

enum AnnotationTool: String, CaseIterable {
    case rectangle
    case arrow
    case numberMarker
    case text
    case mosaic
}

enum Annotation {
    case rectangle(rect: CGRect, color: NSColor, lineWidth: CGFloat, filled: Bool)
    case arrow(start: CGPoint, end: CGPoint, color: NSColor, lineWidth: CGFloat)
    case numberMarker(center: CGPoint, number: Int, color: NSColor, markerSize: CGFloat)
    case text(origin: CGPoint, value: String, color: NSColor, fontSize: CGFloat)
    case mosaic(rect: CGRect, blockSize: CGFloat)

    var isMosaic: Bool {
        if case .mosaic = self {
            return true
        }
        return false
    }
}

struct OCRLine {
    let text: String
    let boundingBox: CGRect
}

enum ExportDestination {
    case clipboard
    case file(URL)
}

final class EditorState {
    let capture: CaptureResult
    var annotations: [Annotation] = []
    var undoneAnnotations: [Annotation] = []
    var selectedTool: AnnotationTool?
    var selectedAnnotationIndex: Int?
    var ocrLines: [OCRLine] = []
    var nextMarkerNumber: Int = 1

    init(capture: CaptureResult) {
        self.capture = capture
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        selectedAnnotationIndex = annotations.count - 1
        undoneAnnotations.removeAll()
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undoneAnnotations.append(last)
        selectedAnnotationIndex = nil
    }

    func redo() {
        guard let last = undoneAnnotations.popLast() else { return }
        annotations.append(last)
        selectedAnnotationIndex = annotations.count - 1
    }
}

struct AppSettings {
    static let shared = AppSettings()

    let saveDirectory: URL
    let imageFormat: String
    let shortcutDescription: String
    let hidesDockIcon: Bool

    private init() {
        saveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        imageFormat = "png"
        shortcutDescription = "Option + A"
        hidesDockIcon = true
    }
}

private extension CGSize {
    var evenPixelSize: CGSize {
        CGSize(width: CGFloat(Self.evenPixelCount(width)), height: CGFloat(Self.evenPixelCount(height)))
    }

    static func evenPixelCount(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded(.down)))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }
}
