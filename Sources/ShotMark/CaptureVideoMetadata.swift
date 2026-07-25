import AppKit
import AVFoundation

struct CaptureVideoMetadata {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let duration: TimeInterval?

    static func load(from url: URL) async -> CaptureVideoMetadata {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try? await asset.load(.duration)
        let seconds = loadedDuration.map(CMTimeGetSeconds)
        let duration = seconds.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }

        let track = try? await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try? await track?.load(.naturalSize)
        let transform = try? await track?.load(.preferredTransform)
        let transformedSize: CGSize? = if let naturalSize, let transform {
            naturalSize.applying(transform)
        } else {
            naturalSize
        }

        return CaptureVideoMetadata(
            pixelWidth: transformedSize.map { Int(abs($0.width).rounded()) },
            pixelHeight: transformedSize.map { Int(abs($0.height).rounded()) },
            duration: duration
        )
    }
}

final class CaptureVideoThumbnailService {
    static let shared = CaptureVideoThumbnailService()

    private let cache = NSCache<NSURL, NSImage>()

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadThumbnail(
        for url: URL,
        maximumSize: CGSize = CGSize(width: 320, height: 200),
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = cachedThumbnail(for: url) {
            completion(cached)
            return
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, image, _, _, _ in
            let thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
            if let thumbnail {
                self?.cache.setObject(thumbnail, forKey: url as NSURL)
            }
            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }
}
