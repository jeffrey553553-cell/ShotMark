import Foundation

enum ImageSaveFollowUpResult: Equatable {
    case notRequested
    case copied
    case copyFailed
}

enum PostCaptureActions {
    static func copyImageAfterSavingIfNeeded(
        pngData: Data,
        isEnabled: Bool = AppSettings.shared.copyImageAfterSaving,
        copy: (Data) throws -> Void
    ) -> ImageSaveFollowUpResult {
        guard isEnabled else { return .notRequested }
        do {
            try copy(pngData)
            return .copied
        } catch {
            return .copyFailed
        }
    }

    static func saveConfirmation(
        for url: URL,
        followUpResult: ImageSaveFollowUpResult
    ) -> String {
        let base = ExportService.saveConfirmation(for: url)
        switch followUpResult {
        case .notRequested:
            return base
        case .copied:
            return "\(base) · 已复制"
        case .copyFailed:
            return "\(base) · 复制失败"
        }
    }
}
