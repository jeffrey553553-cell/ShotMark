import AppKit
import Foundation

enum LongScreenshotSessionCompletion: String, Codable, Equatable {
    case completedForSave
    case completedForCopy
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .completedForSave: "完成（保存）"
        case .completedForCopy: "完成（复制）"
        case .cancelled: "取消"
        case .failed: "失败"
        }
    }
}

struct LongScreenshotQualityReport: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: TimeInterval
    let completion: LongScreenshotSessionCompletion
    let viewportWidth: Int
    let viewportHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let stitchAttempts: Int
    let acceptedFrames: Int
    let appendedFrames: Int
    let noMovementFrames: Int
    let coveredContentFrames: Int
    let alignmentFailureFrames: Int
    let retryCount: Int
    let directionChangeCount: Int
    let usedAutomaticScrolling: Bool
    let usedCompatibilityCapture: Bool
    let reachedCapacityLimit: Bool
    let averageConfidence: Double
    let minimumConfidence: Double

    var acceptanceRate: Double {
        guard stitchAttempts > 0 else { return 0 }
        return Double(acceptedFrames) / Double(stitchAttempts)
    }
}

final class LongScreenshotQualityReportStore {
    static let shared = LongScreenshotQualityReportStore(fileURL: defaultFileURL)
    static let maximumReportCount = 50

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("ShotMark", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("long-screenshot-sessions.json")
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ report: LongScreenshotQualityReport) {
        lock.lock()
        defer { lock.unlock() }

        var stored = loadUnlocked()
        stored.append(report)
        if stored.count > Self.maximumReportCount {
            stored.removeFirst(stored.count - Self.maximumReportCount)
        }
        persistUnlocked(stored)
    }

    func reports() -> [LongScreenshotQualityReport] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func summaryText(now: Date = Date()) -> String {
        let reports = reports()
        let completed = reports.filter {
            $0.completion == .completedForSave || $0.completion == .completedForCopy
        }
        let averageAcceptance = completed.isEmpty
            ? 0
            : completed.reduce(0) { $0 + $1.acceptanceRate } / Double(completed.count)
        let alignmentFailures = reports.reduce(0) { $0 + $1.alignmentFailureFrames }
        let retries = reports.reduce(0) { $0 + $1.retryCount }
        let capacityStops = reports.filter(\.reachedCapacityLimit).count

        var lines = [
            "ShotMark 长截图诊断摘要",
            "生成时间：\(Self.dateFormatter.string(from: now))",
            "隐私：仅包含尺寸、耗时和拼接统计；不包含截图、文字、应用名或文件路径。",
            "最近会话：\(reports.count)/\(Self.maximumReportCount)",
            "完成：\(completed.count)  取消：\(reports.filter { $0.completion == .cancelled }.count)  失败：\(reports.filter { $0.completion == .failed }.count)",
            "完成会话平均采纳率：\(Int((averageAcceptance * 100).rounded()))%",
            "对齐失败帧：\(alignmentFailures)  自动重试：\(retries)  安全上限停止：\(capacityStops)",
            "",
            "最近 10 次："
        ]

        for report in reports.suffix(10).reversed() {
            let confidence = Int((report.averageConfidence * 100).rounded())
            let mode = report.usedAutomaticScrolling ? "自动+手动" : "手动"
            lines.append(
                "\(Self.dateFormatter.string(from: report.startedAt)) | \(report.completion.displayName) | "
                    + "\(report.outputWidth)x\(report.outputHeight) | \(String(format: "%.1fs", report.durationSeconds)) | "
                    + "采纳 \(report.acceptedFrames)/\(report.stitchAttempts) | 对齐失败 \(report.alignmentFailureFrames) | "
                    + "置信度 \(confidence)% | \(mode)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func loadUnlocked() -> [LongScreenshotQualityReport] {
        guard let data = try? Data(contentsOf: fileURL),
              let reports = try? JSONDecoder().decode([LongScreenshotQualityReport].self, from: data)
        else { return [] }
        return reports
    }

    private func persistUnlocked(_ reports: [LongScreenshotQualityReport]) {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never interrupt capture or export.
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

final class LongScreenshotQualityTracker {
    private let store: LongScreenshotQualityReportStore
    private let startedAt: Date
    private let viewportWidth: Int
    private let viewportHeight: Int

    private var stitchAttempts = 0
    private var acceptedFrames = 0
    private var appendedFrames = 0
    private var noMovementFrames = 0
    private var coveredContentFrames = 0
    private var alignmentFailureFrames = 0
    private var retryCount = 0
    private var directionChangeCount = 0
    private var usedAutomaticScrolling = false
    private var usedCompatibilityCapture = false
    private var reachedCapacityLimit = false
    private var confidenceTotal = 0.0
    private var confidenceSampleCount = 0
    private var minimumConfidence = 1.0
    private var lastDirection: LongScreenshotStitchDirection = .unresolved
    private var isFinished = false

    init(
        viewportSize: CGSize,
        store: LongScreenshotQualityReportStore = .shared,
        startedAt: Date = Date()
    ) {
        self.store = store
        self.startedAt = startedAt
        viewportWidth = max(0, Int(viewportSize.width.rounded()))
        viewportHeight = max(0, Int(viewportSize.height.rounded()))
    }

    func record(_ update: LongScreenshotStitchUpdate) {
        stitchAttempts += 1
        confidenceTotal += update.confidence
        confidenceSampleCount += 1
        minimumConfidence = min(minimumConfidence, update.confidence)

        switch update.outcome {
        case .initialized:
            acceptedFrames += 1
        case .appended:
            acceptedFrames += 1
            appendedFrames += 1
        case .ignoredNoMovement:
            noMovementFrames += 1
        case .ignoredCoveredContent:
            coveredContentFrames += 1
        case .ignoredAlignmentFailed:
            alignmentFailureFrames += 1
        case .reachedMaximumHeight:
            reachedCapacityLimit = true
        }

        if update.direction != .unresolved {
            if lastDirection != .unresolved, lastDirection != update.direction {
                directionChangeCount += 1
            }
            lastDirection = update.direction
        }
        reachedCapacityLimit = reachedCapacityLimit || update.capacityLevel == .limit
    }

    func recordRetry() {
        retryCount += 1
    }

    func recordAutomaticScrollingUsed() {
        usedAutomaticScrolling = true
    }

    func recordCompatibilityCaptureUsed() {
        usedCompatibilityCapture = true
    }

    func finish(
        completion: LongScreenshotSessionCompletion,
        outputSize: CGSize = .zero,
        endedAt: Date = Date()
    ) {
        guard !isFinished else { return }
        isFinished = true
        let report = LongScreenshotQualityReport(
            id: UUID(),
            startedAt: startedAt,
            durationSeconds: max(0, endedAt.timeIntervalSince(startedAt)),
            completion: completion,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            outputWidth: max(0, Int(outputSize.width.rounded())),
            outputHeight: max(0, Int(outputSize.height.rounded())),
            stitchAttempts: stitchAttempts,
            acceptedFrames: acceptedFrames,
            appendedFrames: appendedFrames,
            noMovementFrames: noMovementFrames,
            coveredContentFrames: coveredContentFrames,
            alignmentFailureFrames: alignmentFailureFrames,
            retryCount: retryCount,
            directionChangeCount: directionChangeCount,
            usedAutomaticScrolling: usedAutomaticScrolling,
            usedCompatibilityCapture: usedCompatibilityCapture,
            reachedCapacityLimit: reachedCapacityLimit,
            averageConfidence: confidenceSampleCount == 0 ? 0 : confidenceTotal / Double(confidenceSampleCount),
            minimumConfidence: confidenceSampleCount == 0 ? 0 : minimumConfidence
        )
        store.record(report)
    }
}
