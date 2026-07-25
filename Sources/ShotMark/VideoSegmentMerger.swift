import AVFoundation
import Foundation

enum VideoSegmentMergerError: LocalizedError {
    case noUsableSegments
    case compositionTrackCreationFailed
    case exportSessionCreationFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noUsableSegments:
            return "录制片段为空，无法生成视频。"
        case .compositionTrackCreationFailed:
            return "无法创建录屏合并轨道。"
        case .exportSessionCreationFailed:
            return "无法创建录屏合并任务。"
        case .exportFailed:
            return "录屏片段合并失败。"
        }
    }
}

enum VideoSegmentMerger {
    static func merge(segmentURLs: [URL], outputURL: URL) async throws {
        let existingSegments = segmentURLs.filter {
            guard
                FileManager.default.fileExists(atPath: $0.path),
                let values = try? $0.resourceValues(forKeys: [.fileSizeKey]),
                let fileSize = values.fileSize
            else {
                return false
            }
            return fileSize > 0
        }
        guard !existingSegments.isEmpty else {
            throw VideoSegmentMergerError.noUsableSegments
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        if existingSegments.count == 1 {
            try FileManager.default.moveItem(at: existingSegments[0], to: outputURL)
            return
        }

        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoSegmentMergerError.compositionTrackCreationFailed
        }

        var audioCompositionTracks: [AVMutableCompositionTrack] = []
        var insertionTime = CMTime.zero
        var insertedVideo = false

        for segmentURL in existingSegments {
            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                let timeRange = try await videoTrack.load(.timeRange)
                try videoCompositionTrack.insertTimeRange(
                    timeRange,
                    of: videoTrack,
                    at: insertionTime
                )
                if !insertedVideo {
                    videoCompositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
                }
                insertedVideo = true
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            while audioCompositionTracks.count < audioTracks.count {
                guard let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw VideoSegmentMergerError.compositionTrackCreationFailed
                }
                audioCompositionTracks.append(track)
            }
            for (index, audioTrack) in audioTracks.enumerated() {
                let timeRange = try await audioTrack.load(.timeRange)
                try audioCompositionTracks[index].insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: insertionTime
                )
            }

            insertionTime = CMTimeAdd(insertionTime, duration)
        }

        guard insertedVideo else {
            throw VideoSegmentMergerError.noUsableSegments
        }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw VideoSegmentMergerError.exportSessionCreationFailed
        }

        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
    }
}
