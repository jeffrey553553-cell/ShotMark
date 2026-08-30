import CoreGraphics
import Foundation
import OSLog
import Vision

enum LongScreenshotStitchDirection: Equatable {
    case unresolved
    case downward
    case upward

    var opposite: LongScreenshotStitchDirection {
        switch self {
        case .downward: return .upward
        case .upward: return .downward
        case .unresolved: return .unresolved
        }
    }
}

enum LongScreenshotStitchOutcome {
    case initialized
    case appended(deltaY: Int)
    case ignoredNoMovement
    case ignoredCoveredContent
    case ignoredAlignmentFailed
}

struct LongScreenshotStitchUpdate {
    let outcome: LongScreenshotStitchOutcome
    let mergedImage: CGImage?
    let acceptedFrameCount: Int
    let outputHeight: Int
    let direction: LongScreenshotStitchDirection
    let confidence: Double
}

final class LongScreenshotStitcher {
    private static let logger = Logger(subsystem: "com.local.shotmark", category: "long-screenshot-stitcher")
    private struct RasterImage {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]

        init?(cgImage: CGImage) {
            let imageWidth = cgImage.width
            let imageHeight = cgImage.height
            let imageBytesPerRow = imageWidth * 4
            width = imageWidth
            height = imageHeight
            bytesPerRow = imageBytesPerRow
            var buffer = [UInt8](repeating: 0, count: imageHeight * imageBytesPerRow)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

            let drew = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else { return false }
                guard let context = CGContext(
                    data: baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: imageBytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else {
                    return false
                }
                context.interpolationQuality = .none
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
                return true
            }

            guard drew else { return nil }
            pixels = buffer
        }

        private init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.pixels = pixels
        }

        func croppedRows(startRow: Int, rowCount: Int) -> RasterImage? {
            let safeStartRow = max(0, startRow)
            let safeRowCount = min(rowCount, height - safeStartRow)
            guard safeRowCount > 0 else { return nil }
            let startIndex = safeStartRow * bytesPerRow
            let byteCount = safeRowCount * bytesPerRow
            return RasterImage(
                width: width,
                height: safeRowCount,
                bytesPerRow: bytesPerRow,
                pixels: Array(pixels[startIndex..<(startIndex + byteCount)])
            )
        }

        func blockDifference(
            comparedTo other: RasterImage,
            startRow: Int,
            otherStartRow: Int,
            rowCount: Int,
            xStart: Int,
            xEnd: Int,
            columnStride: Int,
            rowStride: Int
        ) -> Double {
            guard rowCount > 0 else { return 255 }
            guard startRow >= 0, otherStartRow >= 0 else { return 255 }
            guard startRow + rowCount <= height, otherStartRow + rowCount <= other.height else { return 255 }

            let safeXStart = max(0, xStart)
            let safeXEnd = min(min(width, other.width), xEnd)
            guard safeXStart < safeXEnd else { return 255 }

            var total = 0.0
            var count = 0
            let safeColumnStride = max(1, columnStride)
            let safeRowStride = max(1, rowStride)

            for rowOffset in stride(from: 0, to: rowCount, by: safeRowStride) {
                let lhsOffset = (startRow + rowOffset) * bytesPerRow
                let rhsOffset = (otherStartRow + rowOffset) * other.bytesPerRow
                for x in stride(from: safeXStart, to: safeXEnd, by: safeColumnStride) {
                    let lhsIndex = lhsOffset + x * 4
                    let rhsIndex = rhsOffset + x * 4
                    total += colorDifference(comparedTo: other, lhsIndex: lhsIndex, rhsIndex: rhsIndex)
                    count += 1
                }
            }

            return count > 0 ? total / Double(count) : 255
        }

        func copyRows(startRow: Int, rowCount: Int, into destination: inout [UInt8], destinationRow: Int) {
            guard rowCount > 0 else { return }
            for localRow in 0..<rowCount {
                let sourceIndex = (startRow + localRow) * bytesPerRow
                let destinationIndex = (destinationRow + localRow) * bytesPerRow
                destination[destinationIndex..<(destinationIndex + bytesPerRow)] = pixels[sourceIndex..<(sourceIndex + bytesPerRow)]
            }
        }

        func croppedImage(xStart: Int, xEnd: Int, startRow: Int, rowCount: Int) -> CGImage? {
            let safeXStart = max(0, xStart)
            let safeXEnd = min(width, xEnd)
            let safeStartRow = max(0, startRow)
            let safeRowCount = min(rowCount, height - safeStartRow)
            guard safeXStart < safeXEnd, safeRowCount > 0 else { return nil }

            let croppedWidth = safeXEnd - safeXStart
            let croppedBytesPerRow = croppedWidth * 4
            var croppedPixels = [UInt8](repeating: 0, count: safeRowCount * croppedBytesPerRow)
            for localRow in 0..<safeRowCount {
                let sourceIndex = (safeStartRow + localRow) * bytesPerRow + safeXStart * 4
                let destinationIndex = localRow * croppedBytesPerRow
                croppedPixels[destinationIndex..<(destinationIndex + croppedBytesPerRow)] =
                    pixels[sourceIndex..<(sourceIndex + croppedBytesPerRow)]
            }

            let data = Data(croppedPixels) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
            return CGImage(
                width: croppedWidth,
                height: safeRowCount,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: croppedBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        private func colorDifference(comparedTo other: RasterImage, lhsIndex: Int, rhsIndex: Int) -> Double {
            let dr = abs(Int(pixels[lhsIndex]) - Int(other.pixels[rhsIndex]))
            let dg = abs(Int(pixels[lhsIndex + 1]) - Int(other.pixels[rhsIndex + 1]))
            let db = abs(Int(pixels[lhsIndex + 2]) - Int(other.pixels[rhsIndex + 2]))
            let lhsLuma = Int(pixels[lhsIndex]) * 299 + Int(pixels[lhsIndex + 1]) * 587 + Int(pixels[lhsIndex + 2]) * 114
            let rhsLuma = Int(other.pixels[rhsIndex]) * 299 + Int(other.pixels[rhsIndex + 1]) * 587 + Int(other.pixels[rhsIndex + 2]) * 114
            let colorAverage = Double(dr + dg + db) / 3
            let lumaDifference = Double(abs(lhsLuma - rhsLuma)) / 1000
            return colorAverage * 0.42 + lumaDifference * 0.58
        }
    }

    private struct ContentSlice {
        let raster: RasterImage
        let viewportStartRow: Int
        let documentStart: Int

        var rowCount: Int { raster.height }
    }

    private struct ViewportAnchor {
        let raster: RasterImage
        let start: Int
    }

    private struct ViewportOverlayRegion {
        var xStart: Int
        var xEnd: Int
        var rowStart: Int
        var rowEnd: Int
        var observations: Int

        var width: Int { xEnd - xStart }
        var height: Int { rowEnd - rowStart }

        func contains(x: Int, row: Int) -> Bool {
            x >= xStart && x < xEnd && row >= rowStart && row < rowEnd
        }

        func isNear(_ other: ViewportOverlayRegion, margin: Int) -> Bool {
            xStart < other.xEnd + margin
                && xEnd + margin > other.xStart
                && rowStart < other.rowEnd + margin
                && rowEnd + margin > other.rowStart
        }

        mutating func merge(_ other: ViewportOverlayRegion) {
            xStart = min(xStart, other.xStart)
            xEnd = max(xEnd, other.xEnd)
            rowStart = min(rowStart, other.rowStart)
            rowEnd = max(rowEnd, other.rowEnd)
            observations += 1
        }
    }

    private struct OverlapMetrics {
        let averageDifference: Double
        let coreDifference: Double
        let strongBandCount: Int
        let bandCount: Int
        let worstDifference: Double
        let variance: Double
    }

    private struct Match {
        let direction: LongScreenshotStitchDirection
        let deltaY: Int
        let pixelScore: Double
        let corePixelScore: Double
        let totalScore: Double
        let strongBandCount: Int
        let bandCount: Int
        let worstBandScore: Double
        let bandVariance: Double
    }

    private struct MatchSearchResult {
        let best: Match
        let runnerUp: Match?
    }

    private struct VisionAlignmentEstimate {
        let deltaY: Int
        let direction: LongScreenshotStitchDirection
        let agreementCount: Int
        let spread: Int

        var isStrong: Bool {
            agreementCount >= 2 && deltaY >= 8
        }
    }

    private var baseRaster: RasterImage?
    private var lastRaster: RasterImage?
    private var contentSlices: [ContentSlice] = []
    private var headerHeight = 0
    private var footerHeight = 0
    private var leadingStaticWidth = 0
    private var trailingStaticWidth = 0
    private var stitchDirection: LongScreenshotStitchDirection = .unresolved
    private var lastMatch: Match?
    private var cachedMergedImage: CGImage?
    private var currentViewportStart = 0
    private var coveredStart = 0
    private var coveredEnd = 0
    private var viewportAnchors: [ViewportAnchor] = []
    private var viewportOverlayRegions: [ViewportOverlayRegion] = []
    private var rendersMergedImageOnUpdate = true

    private(set) var acceptedFrameCount = 0

    var retainedContentPixelBytes: Int {
        contentSlices.reduce(0) { $0 + $1.raster.pixels.count }
    }

    var retainedViewportAnchorCount: Int {
        viewportAnchors.count
    }

    var outputHeight: Int {
        contentSlices.reduce(0) { $0 + $1.rowCount } + headerHeight + footerHeight
    }

    func reset() {
        baseRaster = nil
        lastRaster = nil
        contentSlices.removeAll()
        headerHeight = 0
        footerHeight = 0
        leadingStaticWidth = 0
        trailingStaticWidth = 0
        stitchDirection = .unresolved
        lastMatch = nil
        cachedMergedImage = nil
        currentViewportStart = 0
        coveredStart = 0
        coveredEnd = 0
        viewportAnchors.removeAll()
        viewportOverlayRegions.removeAll()
        acceptedFrameCount = 0
    }

    func append(
        _ image: CGImage,
        expectedDeltaPixels: Int? = nil,
        expectedDirection: LongScreenshotStitchDirection? = nil,
        maxOutputHeight: Int = 120_000,
        renderMergedImage: Bool = true
    ) -> LongScreenshotStitchUpdate? {
        rendersMergedImageOnUpdate = renderMergedImage
        guard let raster = RasterImage(cgImage: image) else { return nil }
        guard let lastRaster, let baseRaster else {
            self.baseRaster = raster
            self.lastRaster = raster
            contentSlices = [ContentSlice(raster: raster, viewportStartRow: 0, documentStart: 0)]
            stitchDirection = .unresolved
            lastMatch = nil
            cachedMergedImage = image
            viewportAnchors = [ViewportAnchor(raster: raster, start: 0)]
            acceptedFrameCount = 1
            return update(outcome: .initialized, mergedImage: image, confidence: 1)
        }

        guard raster.width == lastRaster.width, raster.height == lastRaster.height else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        if let expectedDirection,
           expectedDirection != .unresolved,
           let lastMatch,
           lastMatch.direction != expectedDirection {
            // Keep historical viewport anchors for revisiting covered content,
            // but never carry cadence from the opposite scroll direction.
            self.lastMatch = nil
        }

        // Sticky navigation can become fixed only after the first scroll. Keep
        // structural header/footer values stable for output composition, while
        // continuously expanding the bands excluded from frame alignment.
        let detectedTopBand = detectStaticBand(previous: lastRaster, current: raster, fromTop: true)
        let maximumStickyGrowth = max(48, min(80, raster.height / 8))
        let topBand = headerHeight == 0
            ? detectedTopBand
            : min(max(headerHeight, detectedTopBand), headerHeight + maximumStickyGrowth)
        // Large blank/placeholder regions can look stationary at the bottom.
        // Once a real footer is established, keep it structural rather than
        // allowing scrollable low-texture content to inflate the fixed band.
        let bottomBand = footerHeight == 0
            ? detectStaticBand(previous: lastRaster, current: raster, fromTop: false)
            : footerHeight
        let leftBand = leadingStaticWidth == 0 ? detectStaticSideBand(previous: lastRaster, current: raster, fromLeading: true) : leadingStaticWidth
        let rightBand = trailingStaticWidth == 0 ? detectStaticSideBand(previous: lastRaster, current: raster, fromLeading: false) : trailingStaticWidth

        let frameDifference = contentDifference(
            previous: lastRaster,
            current: raster,
            headerHeight: topBand,
            footerHeight: bottomBand,
            leadingStaticWidth: leftBand,
            trailingStaticWidth: rightBand
        )
        var visionEstimate: VisionAlignmentEstimate?
        var alignmentDirection = expectedDirection
            ?? (stitchDirection != .unresolved ? stitchDirection : nil)

        var adjacentMatch = bestMatch(
            previous: lastRaster,
            current: raster,
            headerHeight: topBand,
            footerHeight: bottomBand,
            leadingStaticWidth: leftBand,
            trailingStaticWidth: rightBand,
            expectedDeltaPixels: expectedDeltaPixels,
            expectedDirection: alignmentDirection,
            visionEstimate: nil
        )

        // Scroll events already provide a strong direction and distance hint. Pixel
        // matching is both more exact and substantially cheaper than running Vision
        // on every stream frame, so reserve feature matching for recovery only.
        if !isAcceptable(adjacentMatch, expectedDeltaPixels: expectedDeltaPixels) {
            visionEstimate = estimateVisionAlignment(
                previous: lastRaster,
                current: raster,
                headerHeight: topBand,
                footerHeight: bottomBand,
                leadingStaticWidth: leftBand,
                trailingStaticWidth: rightBand
            )
            alignmentDirection = expectedDirection
                ?? (visionEstimate?.isStrong == true ? visionEstimate?.direction : nil)
                ?? (stitchDirection != .unresolved ? stitchDirection : nil)
            adjacentMatch = bestMatch(
                previous: lastRaster,
                current: raster,
                headerHeight: topBand,
                footerHeight: bottomBand,
                leadingStaticWidth: leftBand,
                trailingStaticWidth: rightBand,
                expectedDeltaPixels: expectedDeltaPixels,
                expectedDirection: alignmentDirection,
                visionEstimate: visionEstimate
            )
        }
        if adjacentMatch == nil,
           expectedDirection == nil,
           let alignmentDirection,
           alignmentDirection != .unresolved {
            adjacentMatch = bestMatch(
                previous: lastRaster,
                current: raster,
                headerHeight: topBand,
                footerHeight: bottomBand,
                leadingStaticWidth: leftBand,
                trailingStaticWidth: rightBand,
                expectedDeltaPixels: expectedDeltaPixels,
                expectedDirection: alignmentDirection.opposite,
                visionEstimate: visionEstimate
            )
        }
        let resolutionDirection = adjacentMatch?.direction ?? alignmentDirection
        let resolved = resolvedMatch(
            adjacentMatch: adjacentMatch,
            adjacentStart: currentViewportStart,
            current: raster,
            headerHeight: topBand,
            footerHeight: bottomBand,
            leadingStaticWidth: leftBand,
            trailingStaticWidth: rightBand,
            expectedDirection: resolutionDirection
        )
        let candidateMatch = resolved?.match

        if ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_DIAGNOSTICS"] == "1" {
            let visionText = visionEstimate.map {
                "\($0.direction):\($0.deltaY):\($0.agreementCount):\($0.spread)"
            } ?? "none"
            let matchText = adjacentMatch.map {
                "\($0.direction):\($0.deltaY):\($0.pixelScore):\($0.totalScore):\($0.strongBandCount)/\($0.bandCount):\($0.worstBandScore)"
            } ?? "none"
            let message = "bands=\(topBand)/\(bottomBand)/\(leftBand)/\(rightBand) diff=\(frameDifference) vision=\(visionText) match=\(matchText)"
            Self.logger.debug("\(message, privacy: .public)")
        }

#if DEBUG
        if ProcessInfo.processInfo.environment["SHOTMARK_STITCH_DIAGNOSTICS"] == "1" {
            let visionText = visionEstimate.map { "direction=\($0.direction), delta=\($0.deltaY), agreements=\($0.agreementCount), spread=\($0.spread)" } ?? "none"
            let matchText = adjacentMatch.map {
                "direction=\($0.direction), delta=\($0.deltaY), pixel=\($0.pixelScore), total=\($0.totalScore), bands=\($0.strongBandCount)/\($0.bandCount), worst=\($0.worstBandScore)"
            } ?? "none"
            print("LONGSHOT_DIAGNOSTIC bands=\(topBand)/\(bottomBand)/\(leftBand)/\(rightBand) frameDifference=\(frameDifference) vision=[\(visionText)] adjacent=[\(matchText)]")
        }
#endif

        if frameDifference < 2.4,
           visionEstimate?.isStrong != true,
           !hasReliablePixelMotion(match: candidateMatch, expectedDeltaPixels: expectedDeltaPixels) {
            return update(outcome: .ignoredNoMovement, confidence: 1)
        }

        if frameDifference < 8.5,
           visionEstimate?.isStrong != true,
           isLikelyBoundaryOrDuplicate(match: candidateMatch, expectedDeltaPixels: expectedDeltaPixels) {
            return update(outcome: .ignoredNoMovement, confidence: 1)
        }

        guard let resolved, isAcceptable(candidateMatch, expectedDeltaPixels: resolved.usedHistoricalAnchor ? nil : expectedDeltaPixels) else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }
        let match = resolved.match

        if stitchDirection == .unresolved {
            let refinedHeaderHeight = detectStaticBand(
                previous: lastRaster,
                current: raster,
                fromTop: true,
                scrollingDelta: match.deltaY,
                direction: match.direction
            )
            let refinedFooterHeight = detectStaticBand(
                previous: lastRaster,
                current: raster,
                fromTop: false,
                scrollingDelta: match.deltaY,
                direction: match.direction
            )
            headerHeight = refinedHeaderHeight > 0 ? refinedHeaderHeight : topBand
            footerHeight = refinedFooterHeight > 0 ? refinedFooterHeight : bottomBand
#if DEBUG
            if ProcessInfo.processInfo.environment["SHOTMARK_STITCH_DIAGNOSTICS"] == "1" {
                print("LONGSHOT_FIXED_BANDS initial=\(topBand)/\(bottomBand) refined=\(headerHeight)/\(footerHeight)")
            }
#endif
            leadingStaticWidth = leftBand
            trailingStaticWidth = rightBand
            bootstrapBaseContent(from: baseRaster)
        }

        observeViewportOverlays(
            previous: lastRaster,
            current: raster,
            deltaY: match.deltaY,
            direction: match.direction
        )

        stitchDirection = match.direction
        let contentHeight = raster.height - headerHeight - footerHeight
        guard contentHeight > 0 else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        let nextViewportStart: Int
        let novelRowCount: Int
        switch match.direction {
        case .downward:
            nextViewportStart = resolved.anchorStart + match.deltaY
            novelRowCount = max(0, nextViewportStart + contentHeight - coveredEnd)
        case .upward:
            nextViewportStart = resolved.anchorStart - match.deltaY
            novelRowCount = max(0, coveredStart - nextViewportStart)
        case .unresolved:
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        currentViewportStart = nextViewportStart
        self.lastRaster = raster
        self.lastMatch = match
        rememberViewport(raster, start: nextViewportStart)

        guard novelRowCount > 0 else {
            return update(outcome: .ignoredCoveredContent, confidence: confidence(for: match))
        }

        let remainingHeight = maxOutputHeight - outputHeight
        guard remainingHeight > 0 else {
            return update(outcome: .ignoredAlignmentFailed, confidence: confidence(for: match))
        }

        let acceptedDelta = min(novelRowCount, remainingHeight)
        guard let startRow = sliceStartRow(for: match.direction, in: raster, deltaY: acceptedDelta) else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        let documentStart = nextViewportStart + startRow - headerHeight
        guard let sliceRaster = raster.croppedRows(startRow: startRow, rowCount: acceptedDelta) else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }
        let slice = ContentSlice(
            raster: sliceRaster,
            viewportStartRow: startRow,
            documentStart: documentStart
        )
        switch match.direction {
        case .downward:
            contentSlices.append(slice)
            coveredEnd += acceptedDelta
        case .upward:
            contentSlices.insert(slice, at: 0)
            coveredStart -= acceptedDelta
        case .unresolved:
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        cachedMergedImage = nil
        acceptedFrameCount += 1
        return update(outcome: .appended(deltaY: acceptedDelta), confidence: confidence(for: match))
    }

    func mergedImage() -> CGImage? {
        if let cachedMergedImage {
            return cachedMergedImage
        }
        guard let baseRaster else { return nil }
        let width = baseRaster.width
        let height = outputHeight
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: height * baseRaster.bytesPerRow)
        var destinationRow = 0
        if headerHeight > 0 {
            baseRaster.copyRows(
                startRow: 0,
                rowCount: headerHeight,
                into: &pixels,
                destinationRow: destinationRow
            )
            destinationRow += headerHeight
        }
        for slice in contentSlices {
            copyContentSlice(slice, into: &pixels, destinationRow: destinationRow)
            destinationRow += slice.rowCount
        }
        compositeViewportOverlaysOnce(into: &pixels, contentDestinationStart: headerHeight)
        if footerHeight > 0 {
            let footerRaster = lastRaster ?? baseRaster
            footerRaster.copyRows(
                startRow: footerRaster.height - footerHeight,
                rowCount: footerHeight,
                into: &pixels,
                destinationRow: destinationRow
            )
        }

        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: baseRaster.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        cachedMergedImage = image
        return image
    }

    private var activeViewportOverlayRegions: [ViewportOverlayRegion] {
        viewportOverlayRegions.filter { $0.observations >= 2 }
    }

    private func observeViewportOverlays(
        previous: RasterImage,
        current: RasterImage,
        deltaY: Int,
        direction: LongScreenshotStitchDirection
    ) {
        guard direction != .unresolved, deltaY > 0 else { return }
        let contentStart = headerHeight
        let contentEnd = previous.height - footerHeight
        guard contentEnd - contentStart > 96 else { return }

        let cellSize = max(12, min(28, previous.width / 26))
        let columns = Int(ceil(Double(previous.width) / Double(cellSize)))
        let rows = Int(ceil(Double(contentEnd - contentStart) / Double(cellSize)))
        guard columns > 0, rows > 0 else { return }

        var candidates = [Bool](repeating: false, count: columns * rows)
        for rowIndex in 0..<rows {
            let rowStart = contentStart + rowIndex * cellSize
            let rowCount = min(cellSize, contentEnd - rowStart)
            guard rowCount >= 6 else { continue }
            for columnIndex in 0..<columns {
                let xStart = columnIndex * cellSize
                let xEnd = min(previous.width, xStart + cellSize)
                guard xEnd - xStart >= 6 else { continue }

                let sameScreenDifference = previous.blockDifference(
                    comparedTo: current,
                    startRow: rowStart,
                    otherStartRow: rowStart,
                    rowCount: rowCount,
                    xStart: xStart,
                    xEnd: xEnd,
                    columnStride: max(1, (xEnd - xStart) / 8),
                    rowStride: max(1, rowCount / 8)
                )

                let alignedRows: (Int, Int)
                switch direction {
                case .downward:
                    alignedRows = (rowStart + deltaY, rowStart)
                case .upward:
                    alignedRows = (rowStart, rowStart + deltaY)
                case .unresolved:
                    continue
                }
                guard alignedRows.0 >= contentStart,
                      alignedRows.1 >= contentStart,
                      alignedRows.0 + rowCount <= contentEnd,
                      alignedRows.1 + rowCount <= contentEnd else {
                    continue
                }

                let scrollingContentDifference = previous.blockDifference(
                    comparedTo: current,
                    startRow: alignedRows.0,
                    otherStartRow: alignedRows.1,
                    rowCount: rowCount,
                    xStart: xStart,
                    xEnd: xEnd,
                    columnStride: max(1, (xEnd - xStart) / 8),
                    rowStride: max(1, rowCount / 8)
                )
                let isScreenStationary = sameScreenDifference < 15
                    && scrollingContentDifference > max(10, sameScreenDifference * 1.45 + 2)
                candidates[rowIndex * columns + columnIndex] = isScreenStationary
            }
        }

        var visited = [Bool](repeating: false, count: candidates.count)
        var observations: [ViewportOverlayRegion] = []
        for startIndex in candidates.indices where candidates[startIndex] && !visited[startIndex] {
            var queue = [startIndex]
            visited[startIndex] = true
            var cursor = 0
            var minimumColumn = startIndex % columns
            var maximumColumn = minimumColumn
            var minimumRow = startIndex / columns
            var maximumRow = minimumRow
            var cellCount = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                cellCount += 1
                let row = index / columns
                let column = index % columns
                minimumColumn = min(minimumColumn, column)
                maximumColumn = max(maximumColumn, column)
                minimumRow = min(minimumRow, row)
                maximumRow = max(maximumRow, row)

                for (nextRow, nextColumn) in [(row - 1, column), (row + 1, column), (row, column - 1), (row, column + 1)]
                where nextRow >= 0 && nextRow < rows && nextColumn >= 0 && nextColumn < columns {
                    let nextIndex = nextRow * columns + nextColumn
                    if candidates[nextIndex], !visited[nextIndex] {
                        visited[nextIndex] = true
                        queue.append(nextIndex)
                    }
                }
            }

            let xStart = minimumColumn * cellSize
            let xEnd = min(previous.width, (maximumColumn + 1) * cellSize)
            let rowStart = contentStart + minimumRow * cellSize
            let rowEnd = min(contentEnd, contentStart + (maximumRow + 1) * cellSize)
            let width = xEnd - xStart
            let height = rowEnd - rowStart
            guard cellCount >= 3,
                  width >= cellSize,
                  height >= cellSize,
                  width <= previous.width / 2,
                  height <= (contentEnd - contentStart) / 2 else {
                continue
            }
            observations.append(ViewportOverlayRegion(
                // Animated fixed widgets often expose only their stable text or
                // center cells. Include one neighboring cell so their moving
                // edges and shadows are removed with the detected core.
                xStart: max(0, xStart - cellSize),
                xEnd: min(previous.width, xEnd + cellSize),
                rowStart: max(contentStart, rowStart - cellSize * 2),
                rowEnd: min(contentEnd, rowEnd + cellSize * 2),
                observations: 1
            ))
        }

        var changed = false
        for observation in observations {
            if let index = viewportOverlayRegions.firstIndex(where: { $0.isNear(observation, margin: cellSize) }) {
                viewportOverlayRegions[index].merge(observation)
            } else {
                viewportOverlayRegions.append(observation)
            }
            changed = true
        }
        if changed {
            cachedMergedImage = nil
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["SHOTMARK_STITCH_DIAGNOSTICS"] == "1" {
            let observed = observations.map {
                "\($0.xStart),\($0.rowStart),\($0.width)x\($0.height)"
            }.joined(separator: ";")
            let active = activeViewportOverlayRegions.map {
                "\($0.xStart),\($0.rowStart),\($0.width)x\($0.height):\($0.observations)"
            }.joined(separator: ";")
            print("LONGSHOT_OVERLAY observed=[\(observed)] active=[\(active)]")
        }
#endif
    }

    private func copyContentSlice(
        _ slice: ContentSlice,
        into destination: inout [UInt8],
        destinationRow: Int
    ) {
        slice.raster.copyRows(
            startRow: 0,
            rowCount: slice.rowCount,
            into: &destination,
            destinationRow: destinationRow
        )
        let overlays = activeViewportOverlayRegions
        guard !overlays.isEmpty else { return }
        var patchedRows = 0
        var missingRows = 0

        for overlay in overlays {
            let firstLocalRow = max(0, overlay.rowStart - slice.viewportStartRow)
            let finalLocalRow = min(slice.rowCount, overlay.rowEnd - slice.viewportStartRow)
            guard firstLocalRow < finalLocalRow else { continue }
            let xStart = max(0, overlay.xStart)
            let xEnd = min(slice.raster.width, overlay.xEnd)
            guard xStart < xEnd else { continue }

            for localRow in firstLocalRow..<finalLocalRow {
                let documentRow = slice.documentStart + localRow
                let centerX = (xStart + xEnd) / 2
                guard let replacement = bestReplacementAnchor(
                    forDocumentRow: documentRow,
                    x: centerX
                ) else {
                    missingRows += 1
                    continue
                }
                let sourceIndex = replacement.row * replacement.raster.bytesPerRow + xStart * 4
                let destinationIndex = (destinationRow + localRow) * slice.raster.bytesPerRow + xStart * 4
                let byteCount = (xEnd - xStart) * 4
                destination[destinationIndex..<(destinationIndex + byteCount)] =
                    replacement.raster.pixels[sourceIndex..<(sourceIndex + byteCount)]
                patchedRows += 1
            }
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["SHOTMARK_STITCH_DIAGNOSTICS"] == "1",
           patchedRows > 0 || missingRows > 0 {
            print("LONGSHOT_OVERLAY_PATCH document=\(slice.documentStart) rows=\(patchedRows) missing=\(missingRows)")
        }
#endif
    }

    private func bestReplacementAnchor(
        forDocumentRow documentRow: Int,
        x: Int
    ) -> (raster: RasterImage, row: Int)? {
        let contentEnd = (baseRaster?.height ?? 0) - footerHeight
        return viewportAnchors.compactMap { anchor -> (RasterImage, Int, Int)? in
            let viewportRow = headerHeight + documentRow - anchor.start
            guard viewportRow >= headerHeight, viewportRow < contentEnd else { return nil }
            guard !activeViewportOverlayRegions.contains(where: { $0.contains(x: x, row: viewportRow) }) else {
                return nil
            }
            let edgeClearance = min(viewportRow - headerHeight, contentEnd - viewportRow)
            return (anchor.raster, viewportRow, edgeClearance)
        }.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    private func compositeViewportOverlaysOnce(
        into destination: inout [UInt8],
        contentDestinationStart: Int
    ) {
        guard let baseRaster else { return }
        for overlay in activeViewportOverlayRegions {
            let destinationStart = contentDestinationStart + overlay.rowStart - headerHeight
            let rowCount = min(overlay.height, outputHeight - destinationStart - footerHeight)
            let xStart = max(0, overlay.xStart)
            let xEnd = min(baseRaster.width, overlay.xEnd)
            guard destinationStart >= contentDestinationStart, rowCount > 0, xStart < xEnd else { continue }
            for localRow in 0..<rowCount {
                let sourceIndex = (overlay.rowStart + localRow) * baseRaster.bytesPerRow + xStart * 4
                let destinationIndex = (destinationStart + localRow) * baseRaster.bytesPerRow + xStart * 4
                let byteCount = (xEnd - xStart) * 4
                destination[destinationIndex..<(destinationIndex + byteCount)] =
                    baseRaster.pixels[sourceIndex..<(sourceIndex + byteCount)]
            }
        }
    }


    private func update(outcome: LongScreenshotStitchOutcome, mergedImage: CGImage? = nil, confidence: Double) -> LongScreenshotStitchUpdate {
        LongScreenshotStitchUpdate(
            outcome: outcome,
            mergedImage: mergedImage ?? (rendersMergedImageOnUpdate ? self.mergedImage() : nil),
            acceptedFrameCount: acceptedFrameCount,
            outputHeight: outputHeight,
            direction: stitchDirection,
            confidence: confidence
        )
    }

    private func bootstrapBaseContent(from raster: RasterImage) {
        let startRow = headerHeight
        let rowCount = max(1, raster.height - headerHeight - footerHeight)
        guard let contentRaster = raster.croppedRows(startRow: startRow, rowCount: rowCount) else { return }
        contentSlices = [ContentSlice(
            raster: contentRaster,
            viewportStartRow: startRow,
            documentStart: 0
        )]
        currentViewportStart = 0
        coveredStart = 0
        coveredEnd = rowCount
        cachedMergedImage = nil
    }

    private struct ResolvedMatch {
        let match: Match
        let anchorStart: Int
        let usedHistoricalAnchor: Bool
    }

    private func resolvedMatch(
        adjacentMatch: Match?,
        adjacentStart: Int,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int,
        expectedDirection: LongScreenshotStitchDirection?
    ) -> ResolvedMatch? {
        if let adjacentMatch {
            return ResolvedMatch(
                match: adjacentMatch,
                anchorStart: adjacentStart,
                usedHistoricalAnchor: false
            )
        }

        var candidates: [ResolvedMatch] = []
        for anchor in viewportAnchors.reversed() {
            let visionEstimate = estimateVisionAlignment(
                previous: anchor.raster,
                current: current,
                headerHeight: headerHeight,
                footerHeight: footerHeight,
                leadingStaticWidth: leadingStaticWidth,
                trailingStaticWidth: trailingStaticWidth
            )
            guard let match = bestMatch(
                previous: anchor.raster,
                current: current,
                headerHeight: headerHeight,
                footerHeight: footerHeight,
                leadingStaticWidth: leadingStaticWidth,
                trailingStaticWidth: trailingStaticWidth,
                expectedDeltaPixels: nil,
                expectedDirection: expectedDirection,
                visionEstimate: visionEstimate
            ) else {
                continue
            }
            candidates.append(ResolvedMatch(
                match: match,
                anchorStart: anchor.start,
                usedHistoricalAnchor: true
            ))
        }

        return candidates.min { lhs, rhs in
            if abs(lhs.match.totalScore - rhs.match.totalScore) > 0.4 {
                return lhs.match.totalScore < rhs.match.totalScore
            }
            return abs(lhs.anchorStart - currentViewportStart) < abs(rhs.anchorStart - currentViewportStart)
        }
    }

    private func rememberViewport(_ raster: RasterImage, start: Int) {
        let replacementTolerance = max(4, raster.height / 80)
        if let index = viewportAnchors.lastIndex(where: { abs($0.start - start) <= replacementTolerance }) {
            viewportAnchors[index] = ViewportAnchor(raster: raster, start: start)
        } else {
            viewportAnchors.append(ViewportAnchor(raster: raster, start: start))
        }

        let maximumAnchorCount = 64
        guard viewportAnchors.count > maximumAnchorCount else { return }
        let firstIndex = viewportAnchors.indices.min(by: { viewportAnchors[$0].start < viewportAnchors[$1].start })
        let lastIndex = viewportAnchors.indices.max(by: { viewportAnchors[$0].start < viewportAnchors[$1].start })
        let newestIndex = viewportAnchors.indices.last
        let protected = Set([firstIndex, lastIndex, newestIndex].compactMap { $0 })
        let removable = viewportAnchors.indices
            .filter { !protected.contains($0) }
            .min { lhs, rhs in
                nearestAnchorDistance(at: lhs) < nearestAnchorDistance(at: rhs)
            }
        if let removable {
            viewportAnchors.remove(at: removable)
        }
    }

    private func nearestAnchorDistance(at index: Int) -> Int {
        viewportAnchors.indices
            .filter { $0 != index }
            .map { abs(viewportAnchors[$0].start - viewportAnchors[index].start) }
            .min() ?? .max
    }

    private func sliceStartRow(for direction: LongScreenshotStitchDirection, in raster: RasterImage, deltaY: Int) -> Int? {
        switch direction {
        case .downward:
            let contentBottom = raster.height - footerHeight
            let startRow = contentBottom - deltaY
            return startRow >= headerHeight ? startRow : nil
        case .upward:
            let contentBottom = raster.height - footerHeight
            return headerHeight + deltaY <= contentBottom ? headerHeight : nil
        case .unresolved:
            return nil
        }
    }

    private func detectStaticBand(
        previous: RasterImage,
        current: RasterImage,
        fromTop: Bool,
        scrollingDelta: Int? = nil,
        direction: LongScreenshotStitchDirection = .unresolved
    ) -> Int {
        let maxBand = min(previous.height / 3, 420)
        let step = max(2, min(8, previous.height / 180))
        let xInset = max(12, previous.width / 20)
        let xStart = xInset
        let xEnd = max(xStart + 1, previous.width - xInset)
        var bandHeight = 0
        var gapCount = 0

        for offset in stride(from: 0, to: maxBand, by: step) {
            let row = fromTop ? offset : previous.height - 1 - offset
            let difference = staticBandDifference(
                previous: previous,
                current: current,
                previousRow: row,
                currentRow: row,
                rowCount: 1,
                xStart: xStart,
                xEnd: xEnd,
                laneCount: 9
            )
            let movingDifference = scrollingDelta.flatMap { delta in
                movingRowDifference(
                    previous: previous,
                    current: current,
                    row: row,
                    delta: delta,
                    direction: direction,
                    xStart: xStart,
                    xEnd: xEnd
                )
            }
            let isVisuallyFixed = difference < 6.5
                || (difference < 18 && movingDifference.map { $0 > difference * 1.3 + 2 } == true)
            if isVisuallyFixed {
                bandHeight = offset + step
                gapCount = 0
            } else {
                gapCount += 1
            }
            if gapCount >= 3, offset > step * 3 {
                break
            }
        }

        return min(max(0, bandHeight), maxBand)
    }

    private func movingRowDifference(
        previous: RasterImage,
        current: RasterImage,
        row: Int,
        delta: Int,
        direction: LongScreenshotStitchDirection,
        xStart: Int,
        xEnd: Int
    ) -> Double? {
        let pairs: [(Int, Int)]
        switch direction {
        case .downward:
            pairs = [(row + delta, row), (row, row - delta)]
        case .upward:
            pairs = [(row, row + delta), (row - delta, row)]
        case .unresolved:
            return nil
        }

        for (previousRow, currentRow) in pairs
        where previousRow >= 0 && previousRow < previous.height && currentRow >= 0 && currentRow < current.height {
            return staticBandDifference(
                previous: previous,
                current: current,
                previousRow: previousRow,
                currentRow: currentRow,
                rowCount: 1,
                xStart: xStart,
                xEnd: xEnd,
                laneCount: 9
            )
        }
        return nil
    }

    private func detectStaticSideBand(previous: RasterImage, current: RasterImage, fromLeading: Bool) -> Int {
        let maxBand = min(previous.width / 5, 160)
        let step = max(2, min(8, previous.width / 180))
        let yInset = max(12, previous.height / 18)
        let yStart = yInset
        let yEnd = max(yStart + 1, previous.height - yInset)
        var bandWidth = 0

        for offset in stride(from: 0, to: maxBand, by: step) {
            let xStart = fromLeading ? offset : previous.width - 1 - offset
            let difference = previous.blockDifference(
                comparedTo: current,
                startRow: yStart,
                otherStartRow: yStart,
                rowCount: yEnd - yStart,
                xStart: xStart,
                xEnd: min(previous.width, xStart + 1),
                columnStride: 1,
                rowStride: max(2, (yEnd - yStart) / 52)
            )
            if difference < 5 {
                bandWidth = offset + step
            } else if offset > step * 2 {
                break
            }
        }

        return min(max(0, bandWidth), maxBand)
    }

    private func contentDifference(
        previous: RasterImage,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int
    ) -> Double {
        let contentHeight = previous.height - headerHeight - footerHeight
        guard contentHeight > 24, let xBounds = matchingColumnBounds(
            previous: previous,
            current: current,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            leadingStaticWidth: leadingStaticWidth,
            trailingStaticWidth: trailingStaticWidth
        ) else {
            return 255
        }

        let bandHeight = max(12, min(24, contentHeight / 8))
        var total = 0.0
        let bandCount = 8
        for index in 0..<bandCount {
            let ratio = Double(index + 1) / Double(bandCount + 1)
            let row = headerHeight + min(max(0, contentHeight - bandHeight), Int(Double(contentHeight - bandHeight) * ratio))
            total += robustBlockDifference(
                previous: previous,
                current: current,
                previousRow: row,
                currentRow: row,
                rowCount: bandHeight,
                xStart: xBounds.lowerBound,
                xEnd: xBounds.upperBound,
                laneCount: 10
            )
        }
        return total / Double(bandCount)
    }

    private func bestMatch(
        previous: RasterImage,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int,
        expectedDeltaPixels: Int?,
        expectedDirection: LongScreenshotStitchDirection?,
        visionEstimate: VisionAlignmentEstimate?
    ) -> Match? {
        let contentHeight = previous.height - headerHeight - footerHeight
        guard contentHeight > 48 else { return nil }

        let minDelta = max(12, min(120, contentHeight / 32))
        let minOverlap: Int
        if expectedDeltaPixels != nil {
            // A real wheel/auto-scroll hint makes a shorter exact overlap safe
            // and lets fast scrolling recover on viewports with large sticky bars.
            minOverlap = max(64, Int(Double(contentHeight) * 0.12))
        } else {
            minOverlap = max(96, Int(Double(contentHeight) * 0.20))
        }
        let maxDelta = max(minDelta, contentHeight - minOverlap)
        guard maxDelta > minDelta else { return nil }

        let focusedRange = focusedDeltaRange(
            minDelta: minDelta,
            maxDelta: maxDelta,
            expectedDeltaPixels: expectedDeltaPixels,
            visionEstimate: visionEstimate
        )
        let expectedHintMatch: Match? = {
            guard let expectedDeltaPixels,
                  let direction = expectedDirection,
                  direction != .unresolved else { return nil }
            let delta = min(maxDelta, max(minDelta, expectedDeltaPixels))
            guard let metrics = overlapMetrics(
                previous: previous,
                current: current,
                direction: direction,
                deltaY: delta,
                headerHeight: headerHeight,
                footerHeight: footerHeight,
                leadingStaticWidth: leadingStaticWidth,
                trailingStaticWidth: trailingStaticWidth
            ) else { return nil }
            return makeMatch(
                direction: direction,
                deltaY: delta,
                metrics: metrics,
                expectedDeltaPixels: expectedDeltaPixels,
                visionEstimate: visionEstimate
            )
        }()
#if DEBUG
        if ProcessInfo.processInfo.environment["SHOTMARK_STITCH_DIAGNOSTICS"] == "1",
           let expectedHintMatch {
            print(
                "LONGSHOT_EXPECTED_HINT direction=\(expectedHintMatch.direction), delta=\(expectedHintMatch.deltaY), "
                    + "pixel=\(expectedHintMatch.pixelScore), total=\(expectedHintMatch.totalScore), "
                    + "bands=\(expectedHintMatch.strongBandCount)/\(expectedHintMatch.bandCount), "
                    + "worst=\(expectedHintMatch.worstBandScore)"
            )
        }
#endif
        if let expectedHintMatch,
           expectedHintMatch.pixelScore <= 0.35,
           expectedHintMatch.worstBandScore <= 1.2,
           expectedHintMatch.strongBandCount == expectedHintMatch.bandCount {
            // Exact stream/wheel hints are conclusive. Avoid scanning the full
            // displacement range on every smooth-scroll frame.
            return expectedHintMatch
        }
        var search = searchBestMatch(
            previous: previous,
            current: current,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            leadingStaticWidth: leadingStaticWidth,
            trailingStaticWidth: trailingStaticWidth,
            deltaRange: focusedRange ?? minDelta...maxDelta,
            expectedDeltaPixels: expectedDeltaPixels,
            expectedDirection: expectedDirection,
            visionEstimate: visionEstimate
        )

        let focusedMatchNeedsVerification = search.map { result in
            result.best.pixelScore > 0.35
                || !isAcceptable(result.best, expectedDeltaPixels: expectedDeltaPixels)
                || isAmbiguous(result, expectedDeltaPixels: expectedDeltaPixels)
        } ?? true
        if focusedMatchNeedsVerification {
            if focusedRange != nil {
                // Scroll-wheel deltas describe input motion, not necessarily the
                // final viewport displacement. Recovery must be able to ignore
                // that prior when momentum, animation, or app-specific scrolling
                // makes it misleading.
                let recoveryExpectedDelta = visionEstimate?.isStrong == true ? expectedDeltaPixels : nil
                let broad = searchBestMatch(
                    previous: previous,
                    current: current,
                    headerHeight: headerHeight,
                    footerHeight: footerHeight,
                    leadingStaticWidth: leadingStaticWidth,
                    trailingStaticWidth: trailingStaticWidth,
                    deltaRange: minDelta...maxDelta,
                    expectedDeltaPixels: recoveryExpectedDelta,
                    expectedDirection: expectedDirection,
                    visionEstimate: visionEstimate
                )
                if shouldPreferBroadMatch(broad?.best, over: search?.best) {
                    search = broad
                }
            }
        }

        if let expectedHintMatch,
           isReliableExpectedHintMatch(expectedHintMatch),
           (search == nil
                || !isAcceptable(search?.best, expectedDeltaPixels: expectedDeltaPixels)
                || isAmbiguous(search, expectedDeltaPixels: expectedDeltaPixels)
                || shouldPreferBroadMatch(expectedHintMatch, over: search?.best)) {
            return expectedHintMatch
        }

        guard let search, isAcceptable(search.best, expectedDeltaPixels: expectedDeltaPixels), !isAmbiguous(search, expectedDeltaPixels: expectedDeltaPixels) else {
            return nil
        }
        return search.best
    }

    private func shouldPreferBroadMatch(_ broad: Match?, over focused: Match?) -> Bool {
        guard let broad else { return false }
        guard let focused else { return true }

        // A wheel delta is an input hint, not the resulting viewport movement.
        // Prefer substantially stronger image evidence even when momentum or
        // frame coalescing moved farther than the focused search expected.
        if broad.pixelScore + 0.75 < focused.pixelScore {
            return true
        }
        if abs(broad.pixelScore - focused.pixelScore) <= 0.75 {
            return broad.totalScore < focused.totalScore
        }
        return false
    }

    private func isReliableExpectedHintMatch(_ match: Match) -> Bool {
        let strongBandRatio = Double(match.strongBandCount) / Double(max(1, match.bandCount))
        return match.pixelScore <= 12.5
            && match.totalScore < 30
            && (strongBandRatio >= 0.66
                || (strongBandRatio >= 0.5 && match.corePixelScore <= 4))
    }

    private func focusedDeltaRange(
        minDelta: Int,
        maxDelta: Int,
        expectedDeltaPixels: Int?,
        visionEstimate: VisionAlignmentEstimate?
    ) -> ClosedRange<Int>? {
        if let expectedDeltaPixels,
           expectedDeltaPixels > 0,
           let lastMatch,
           lastMatch.deltaY >= max(72, expectedDeltaPixels * 2) {
            // At a scroll boundary the actual viewport displacement collapses
            // even though the preceding cadence was large. Do not average the
            // small current hint with the old cadence or the true overlap can
            // fall outside the focused search entirely.
            let center = min(maxDelta, max(minDelta, expectedDeltaPixels))
            let spread = max(28, min(72, center / 2 + 12))
            return max(minDelta, center - spread)...min(maxDelta, center + spread)
        }
        var centers: [Int] = []
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            centers.append(min(maxDelta, max(minDelta, expectedDeltaPixels)))
        }
        if let lastMatch {
            centers.append(min(maxDelta, max(minDelta, lastMatch.deltaY)))
        }
        if let visionEstimate, visionEstimate.deltaY > 0 {
            let visionCenter = min(maxDelta, max(minDelta, visionEstimate.deltaY))
            let weight = max(2, visionEstimate.agreementCount + 1)
            centers.append(contentsOf: repeatElement(visionCenter, count: weight))
        }
        guard !centers.isEmpty else { return nil }
        let center = Int(round(Double(centers.reduce(0, +)) / Double(centers.count)))
        let spread = max(28, min(96, center / 2 + 12))
        return max(minDelta, center - spread)...min(maxDelta, center + spread)
    }

    private func searchBestMatch(
        previous: RasterImage,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int,
        deltaRange: ClosedRange<Int>,
        expectedDeltaPixels: Int?,
        expectedDirection: LongScreenshotStitchDirection?,
        visionEstimate: VisionAlignmentEstimate?
    ) -> MatchSearchResult? {
        let contentHeight = previous.height - headerHeight - footerHeight
        let step = max(2, min(10, contentHeight / 160))
        let directions: [LongScreenshotStitchDirection]
        if let expectedDirection, expectedDirection != .unresolved {
            directions = [expectedDirection]
        } else {
            directions = [.downward, .upward]
        }
        var coarseCandidates: [Match] = []

        for direction in directions {
            for delta in stride(from: deltaRange.lowerBound, through: deltaRange.upperBound, by: step) {
                guard let metrics = overlapMetrics(
                    previous: previous,
                    current: current,
                    direction: direction,
                    deltaY: delta,
                    headerHeight: headerHeight,
                    footerHeight: footerHeight,
                    leadingStaticWidth: leadingStaticWidth,
                    trailingStaticWidth: trailingStaticWidth
                ) else {
                    continue
                }
                coarseCandidates.append(makeMatch(
                    direction: direction,
                    deltaY: delta,
                    metrics: metrics,
                    expectedDeltaPixels: expectedDeltaPixels,
                    visionEstimate: visionEstimate
                ))
            }
        }

        guard let coarseBest = coarseCandidates.min(by: { $0.totalScore < $1.totalScore }) else { return nil }
        var refinedBest = coarseBest
        let radius = max(8, step * 2)
        let refineStart = max(deltaRange.lowerBound, coarseBest.deltaY - radius)
        let refineEnd = min(deltaRange.upperBound, coarseBest.deltaY + radius)
        for delta in refineStart...refineEnd {
            guard let metrics = overlapMetrics(
                previous: previous,
                current: current,
                direction: coarseBest.direction,
                deltaY: delta,
                headerHeight: headerHeight,
                footerHeight: footerHeight,
                leadingStaticWidth: leadingStaticWidth,
                trailingStaticWidth: trailingStaticWidth
            ) else {
                continue
            }
            let match = makeMatch(
                direction: coarseBest.direction,
                deltaY: delta,
                metrics: metrics,
                expectedDeltaPixels: expectedDeltaPixels,
                visionEstimate: visionEstimate
            )
            if match.totalScore < refinedBest.totalScore {
                refinedBest = match
            }
        }

        let ambiguityWindow = max(24, step * 3)
        let runnerUp = coarseCandidates
            .filter { candidate in
                candidate.direction != refinedBest.direction || abs(candidate.deltaY - refinedBest.deltaY) > ambiguityWindow
            }
            .min(by: { $0.totalScore < $1.totalScore })

        return MatchSearchResult(best: refinedBest, runnerUp: runnerUp)
    }

    private func makeMatch(
        direction: LongScreenshotStitchDirection,
        deltaY: Int,
        metrics: OverlapMetrics,
        expectedDeltaPixels: Int?,
        visionEstimate: VisionAlignmentEstimate?
    ) -> Match {
        let strongBandRatio = Double(metrics.strongBandCount) / Double(max(1, metrics.bandCount))
        let followsExpectedMovement = expectedDeltaPixels.map {
            abs(deltaY - $0) <= max(12, $0 / 5)
        } ?? false
        let canIgnoreChangingRegions = followsExpectedMovement
            && strongBandRatio >= 0.5
            && metrics.coreDifference <= 4
        let pixelScore = canIgnoreChangingRegions ? metrics.coreDifference : metrics.averageDifference
        let totalScore = pixelScore
            + consistencyPenalty(for: metrics)
            + priorPenalty(
                deltaY: deltaY,
                expectedDeltaPixels: expectedDeltaPixels,
                visionEstimate: visionEstimate
            )
        return Match(
            direction: direction,
            deltaY: deltaY,
            pixelScore: pixelScore,
            corePixelScore: metrics.coreDifference,
            totalScore: totalScore,
            strongBandCount: metrics.strongBandCount,
            bandCount: metrics.bandCount,
            worstBandScore: metrics.worstDifference,
            bandVariance: metrics.variance
        )
    }

    private func overlapMetrics(
        previous: RasterImage,
        current: RasterImage,
        direction: LongScreenshotStitchDirection,
        deltaY: Int,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int
    ) -> OverlapMetrics? {
        let contentHeight = previous.height - headerHeight - footerHeight
        let overlapHeight = contentHeight - deltaY
        guard overlapHeight > 24 else { return nil }
        guard let xBounds = matchingColumnBounds(
            previous: previous,
            current: current,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            leadingStaticWidth: leadingStaticWidth,
            trailingStaticWidth: trailingStaticWidth
        ) else { return nil }

        let bandCount = min(10, max(6, overlapHeight / 80))
        let bandHeight = max(12, min(28, overlapHeight / max(3, bandCount + 1)))
        var differences: [Double] = []
        differences.reserveCapacity(bandCount)

        for index in 0..<bandCount {
            let ratio = Double(index + 1) / Double(bandCount + 1)
            let rowOffset = min(max(0, overlapHeight - bandHeight), Int(Double(overlapHeight - bandHeight) * ratio))
            let previousRow: Int
            let currentRow: Int
            switch direction {
            case .downward:
                previousRow = headerHeight + deltaY + rowOffset
                currentRow = headerHeight + rowOffset
            case .upward:
                previousRow = headerHeight + rowOffset
                currentRow = headerHeight + deltaY + rowOffset
            case .unresolved:
                return nil
            }
            differences.append(robustBlockDifference(
                previous: previous,
                current: current,
                previousRow: previousRow,
                currentRow: currentRow,
                rowCount: bandHeight,
                xStart: xBounds.lowerBound,
                xEnd: xBounds.upperBound,
                laneCount: 10
            ))
        }

        guard !differences.isEmpty else { return nil }
        let sortedDifferences = differences.sorted()
        let retainedCount = max(3, Int(ceil(Double(sortedDifferences.count) * 0.75)))
        let retainedDifferences = sortedDifferences.prefix(retainedCount)
        let average = retainedDifferences.reduce(0, +) / Double(retainedDifferences.count)
        let coreCount = max(3, Int(ceil(Double(sortedDifferences.count) * 0.50)))
        let coreDifferences = sortedDifferences.prefix(coreCount)
        let coreAverage = coreDifferences.reduce(0, +) / Double(coreDifferences.count)
        let median = sortedDifferences[sortedDifferences.count / 2]
        let strongThreshold = max(9.0, min(13.5, median * 1.35))
        let strongBandCount = differences.filter { $0 <= strongThreshold }.count
        let worst = differences.max() ?? average
        let variance = differences.reduce(0.0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(differences.count)
        return OverlapMetrics(
            averageDifference: average,
            coreDifference: coreAverage,
            strongBandCount: strongBandCount,
            bandCount: differences.count,
            worstDifference: worst,
            variance: variance
        )
    }

    private func robustBlockDifference(
        previous: RasterImage,
        current: RasterImage,
        previousRow: Int,
        currentRow: Int,
        rowCount: Int,
        xStart: Int,
        xEnd: Int,
        laneCount: Int
    ) -> Double {
        let laneDifferences = blockDifferencesByLane(
            previous: previous,
            current: current,
            previousRow: previousRow,
            currentRow: currentRow,
            rowCount: rowCount,
            xStart: xStart,
            xEnd: xEnd,
            laneCount: laneCount
        )
        guard !laneDifferences.isEmpty else { return 255 }
        let sorted = laneDifferences.sorted()
        let capIndex = min(sorted.count - 1, Int(floor(Double(sorted.count - 1) * 0.8)))
        let upperCap = sorted[capIndex]
        let winsorized = laneDifferences.map { min($0, upperCap) }
        return winsorized.reduce(0, +) / Double(winsorized.count)
    }

    private func staticBandDifference(
        previous: RasterImage,
        current: RasterImage,
        previousRow: Int,
        currentRow: Int,
        rowCount: Int,
        xStart: Int,
        xEnd: Int,
        laneCount: Int
    ) -> Double {
        let laneDifferences = blockDifferencesByLane(
            previous: previous,
            current: current,
            previousRow: previousRow,
            currentRow: currentRow,
            rowCount: rowCount,
            xStart: xStart,
            xEnd: xEnd,
            laneCount: laneCount
        )
        guard !laneDifferences.isEmpty else { return 255 }

        let overallAverage = laneDifferences.reduce(0, +) / Double(laneDifferences.count)
        let center = laneDifferences.count / 2
        let centerStart = max(0, center - 1)
        let centerEnd = min(laneDifferences.count, center + 2)
        let centerLanes = laneDifferences[centerStart..<centerEnd]
        let centerAverage = centerLanes.reduce(0, +) / Double(centerLanes.count)
        let strongestLane = laneDifferences.max() ?? overallAverage

        // Browser pages often have wide, unchanged gutters around a scrolling
        // document. A trimmed average would classify the whole document as a
        // fixed bar. Keep the center content lanes authoritative while still
        // tolerating a small animated widget near either edge.
        let baseline = max(overallAverage, centerAverage * 0.82)
        let isLocalizedPeak = strongestLane > max(baseline * 3, baseline + 8)
        // A colored row edge or narrow sidebar can occupy just one lane. Keep
        // it from being swallowed into a fixed header even when the remaining
        // row is mostly blank or repeated background. Broad translucent motion
        // remains eligible because it affects the center and average together.
        return isLocalizedPeak ? max(baseline, strongestLane) : baseline
    }

    private func blockDifferencesByLane(
        previous: RasterImage,
        current: RasterImage,
        previousRow: Int,
        currentRow: Int,
        rowCount: Int,
        xStart: Int,
        xEnd: Int,
        laneCount: Int
    ) -> [Double] {
        let width = xEnd - xStart
        guard width > 0 else { return [] }
        let actualLaneCount = max(1, min(laneCount, width / 8))
        let laneWidth = max(1, width / actualLaneCount)
        var laneDifferences: [Double] = []
        laneDifferences.reserveCapacity(actualLaneCount)

        for lane in 0..<actualLaneCount {
            let laneStart = xStart + lane * laneWidth
            let laneEnd = lane == actualLaneCount - 1 ? xEnd : min(xEnd, laneStart + laneWidth)
            guard laneStart < laneEnd else { continue }
            laneDifferences.append(previous.blockDifference(
                comparedTo: current,
                startRow: previousRow,
                otherStartRow: currentRow,
                rowCount: rowCount,
                xStart: laneStart,
                xEnd: laneEnd,
                columnStride: max(1, (laneEnd - laneStart) / 10),
                rowStride: max(1, min(2, rowCount))
            ))
        }
        return laneDifferences
    }

    private func matchingColumnBounds(
        previous: RasterImage,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int
    ) -> ClosedRange<Int>? {
        let width = previous.width
        let inset = max(8, width / 40)
        let start = min(width - 2, max(inset, leadingStaticWidth + inset))
        let end = max(start + 1, min(width - inset, width - trailingStaticWidth - inset))
        guard start < end else { return nil }

        let contentStart = max(0, headerHeight)
        let contentEnd = min(previous.height, previous.height - max(0, footerHeight))
        let contentHeight = contentEnd - contentStart
        guard contentHeight > 48 else { return start...end }

        let binCount = min(72, max(16, width / 48))
        let binWidth = max(8, Int(ceil(Double(width) / Double(binCount))))
        var differences: [Double] = []
        differences.reserveCapacity(binCount)
        for index in 0..<binCount {
            let xStart = index * binWidth
            let xEnd = min(width, xStart + binWidth)
            guard xStart < xEnd else { break }
            differences.append(previous.blockDifference(
                comparedTo: current,
                startRow: contentStart,
                otherStartRow: contentStart,
                rowCount: contentHeight,
                xStart: xStart,
                xEnd: xEnd,
                columnStride: max(1, (xEnd - xStart) / 8),
                rowStride: max(2, contentHeight / 72)
            ))
        }
        guard differences.count >= 8 else { return start...end }

        var active = differences.map { $0 >= 1.35 }
        if active.count >= 3 {
            for index in 1..<(active.count - 1) where !active[index] && active[index - 1] && active[index + 1] {
                active[index] = true
            }
        }

        var clusters: [Range<Int>] = []
        var clusterStart: Int?
        for index in active.indices {
            if active[index], clusterStart == nil {
                clusterStart = index
            }
            if !active[index], let startIndex = clusterStart {
                clusters.append(startIndex..<index)
                clusterStart = nil
            }
        }
        if let clusterStart {
            clusters.append(clusterStart..<active.count)
        }

        let minimumActiveWidth = max(width / 16, binWidth * 3)
        let eligibleClusters = clusters.filter { cluster in
            cluster.count * binWidth >= minimumActiveWidth
        }
        let preferredCluster = eligibleClusters.max { lhs, rhs in
                let lhsWidth = lhs.count * binWidth
                let rhsWidth = rhs.count * binWidth
                if lhsWidth != rhsWidth { return lhsWidth < rhsWidth }
                let lhsDistance = abs((lhs.lowerBound + lhs.upperBound) * binWidth / 2 - width / 2)
                let rhsDistance = abs((rhs.lowerBound + rhs.upperBound) * binWidth / 2 - width / 2)
                return lhsDistance > rhsDistance
        }
        guard let cluster = preferredCluster else {
            return start...end
        }

        let expansion = binWidth * 2
        let activeStart = max(start, cluster.lowerBound * binWidth - expansion)
        let activeEnd = min(end, cluster.upperBound * binWidth + expansion)
        return activeEnd - activeStart >= minimumActiveWidth ? activeStart...activeEnd : start...end
    }

    private func consistencyPenalty(for metrics: OverlapMetrics) -> Double {
        let strongRatio = Double(metrics.strongBandCount) / Double(max(1, metrics.bandCount))
        var penalty = Double(max(0, metrics.bandCount - metrics.strongBandCount)) * 1.0
        if strongRatio < 0.5 {
            penalty += (0.5 - strongRatio) * 8
        }
        if metrics.worstDifference > 18 {
            penalty += min(6, (metrics.worstDifference - 18) * 0.4)
        }
        if metrics.variance > 14 {
            penalty += min(5, (metrics.variance - 14) * 0.3)
        }
        return penalty
    }

    private func priorPenalty(
        deltaY: Int,
        expectedDeltaPixels: Int?,
        visionEstimate: VisionAlignmentEstimate?
    ) -> Double {
        var penalty = 0.0
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            let expectedWeight = visionEstimate?.isStrong == true ? 4.0 : 18.0
            penalty += deviationPenalty(candidate: deltaY, expected: expectedDeltaPixels, weight: expectedWeight)
            if visionEstimate?.isStrong != true,
               deltaY > max(expectedDeltaPixels * 2, expectedDeltaPixels + 180) {
                penalty += 12
            }
        }
        if let lastMatch {
            let historyWeight = visionEstimate?.isStrong == true ? 5.0 : 16.0
            penalty += deviationPenalty(candidate: deltaY, expected: lastMatch.deltaY, weight: historyWeight)
            if visionEstimate?.isStrong != true,
               deltaY > max(lastMatch.deltaY * 2, lastMatch.deltaY + 160) {
                penalty += 10
            }
        }
        if let visionEstimate, visionEstimate.deltaY > 0 {
            let agreementWeight = Double(max(0, visionEstimate.agreementCount - 1)) * 5
            let spreadPenalty = Double(min(visionEstimate.spread, 12)) * 0.35
            penalty += deviationPenalty(
                candidate: deltaY,
                expected: visionEstimate.deltaY,
                weight: 24 + agreementWeight - spreadPenalty
            )
        }
        return penalty
    }

    private func estimateVisionAlignment(
        previous: RasterImage,
        current: RasterImage,
        headerHeight: Int,
        footerHeight: Int,
        leadingStaticWidth: Int,
        trailingStaticWidth: Int
    ) -> VisionAlignmentEstimate? {
        guard let xBounds = matchingColumnBounds(
            previous: previous,
            current: current,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            leadingStaticWidth: leadingStaticWidth,
            trailingStaticWidth: trailingStaticWidth
        ) else {
            return nil
        }

        let contentHeight = previous.height - headerHeight - footerHeight
        guard contentHeight > 96 else { return nil }
        let trim = min(28, max(8, contentHeight / 22))
        let startRow = headerHeight + trim
        let rowCount = contentHeight - trim * 2
        guard rowCount > 72 else { return nil }

        let xStart = xBounds.lowerBound
        let xEnd = xBounds.upperBound
        var regions: [(Int, Int, Int, Int)] = [(xStart, xEnd, startRow, rowCount)]
        let contentWidth = xEnd - xStart
        if contentWidth > 240 {
            let horizontalTrim = max(16, min(44, contentWidth / 7))
            regions.append((xStart + horizontalTrim, xEnd - horizontalTrim, startRow, rowCount))
        }
        if rowCount > 190 {
            let centeredHeight = max(112, Int(Double(rowCount) * 0.68))
            regions.append((xStart, xEnd, startRow + (rowCount - centeredHeight) / 2, centeredHeight))
        }

        let samples = regions.compactMap { region in
            estimateVisionTranslation(
                previous: previous,
                current: current,
                xStart: region.0,
                xEnd: region.1,
                startRow: region.2,
                rowCount: region.3
            )
        }.sorted()
        guard !samples.isEmpty else { return nil }

        var bestCluster: [Int] = []
        for sample in samples {
            let tolerance = max(6, sample / 10)
            let cluster = samples.filter { abs($0 - sample) <= tolerance }
            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
        }
        let accepted = bestCluster.isEmpty ? samples : bestCluster
        let signedDeltaY = accepted[accepted.count / 2]
        let deltaY = abs(signedDeltaY)
        return VisionAlignmentEstimate(
            deltaY: deltaY,
            direction: signedDeltaY < 0 ? .downward : .upward,
            agreementCount: accepted.count,
            spread: max(0, abs((accepted.last ?? signedDeltaY) - (accepted.first ?? signedDeltaY)))
        )
    }

    private func estimateVisionTranslation(
        previous: RasterImage,
        current: RasterImage,
        xStart: Int,
        xEnd: Int,
        startRow: Int,
        rowCount: Int
    ) -> Int? {
        guard let previousImage = previous.croppedImage(
            xStart: xStart,
            xEnd: xEnd,
            startRow: startRow,
            rowCount: rowCount
        ), let currentImage = current.croppedImage(
            xStart: xStart,
            xEnd: xEnd,
            startRow: startRow,
            rowCount: rowCount
        ) else {
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: currentImage,
            options: [:],
            completionHandler: nil
        )
        let handler = VNSequenceRequestHandler()
        do {
            try handler.perform([request], on: previousImage)
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        let transform = observation.alignmentTransform
        let horizontalShift = abs(transform.tx)
        let signedVerticalShift = transform.ty
        let verticalShift = abs(signedVerticalShift)
        guard horizontalShift.isFinite, signedVerticalShift.isFinite else { return nil }
        guard verticalShift >= 6 else { return nil }
        guard horizontalShift <= max(10, CGFloat(previousImage.width) * 0.03) else { return nil }

        let deltaY = Int(signedVerticalShift.rounded())
        let maxUsefulDelta = max(18, rowCount - max(80, Int(Double(rowCount) * 0.14)))
        return abs(deltaY) <= maxUsefulDelta ? deltaY : nil
    }

    private func deviationPenalty(candidate: Int, expected: Int, weight: Double) -> Double {
        let baseline = max(1, expected)
        return Double(abs(candidate - expected)) / Double(baseline) * weight
    }

    private func isAcceptable(_ match: Match?, expectedDeltaPixels: Int?) -> Bool {
        guard let match else { return false }
        guard match.pixelScore < 18, match.totalScore < 30 else { return false }
        let followsExpectedMovement = expectedDeltaPixels.map {
            abs(match.deltaY - $0) <= max(12, $0 / 5)
        } ?? false
        let requiredStrongBands = max(3, match.bandCount / 2)
        let strongBandRatio = Double(match.strongBandCount) / Double(max(1, match.bandCount))
        if match.strongBandCount < requiredStrongBands, match.pixelScore > 8.8 {
            return false
        }
        if match.worstBandScore > 42,
           match.bandVariance > 36,
           strongBandRatio < 0.65,
           !(followsExpectedMovement && match.corePixelScore <= 4) {
            return false
        }
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            let tolerance = max(36, expectedDeltaPixels)
            if abs(match.deltaY - expectedDeltaPixels) > tolerance, match.pixelScore > 10 {
                return false
            }
        }
        return true
    }

    private func isAmbiguous(_ result: MatchSearchResult?, expectedDeltaPixels: Int?) -> Bool {
        guard let result, let runnerUp = result.runnerUp else { return false }
        let best = result.best
        let scoreGap = runnerUp.totalScore - best.totalScore
        let pixelGap = runnerUp.pixelScore - best.pixelScore
        let deltaGap = abs(runnerUp.deltaY - best.deltaY)
        if runnerUp.direction != best.direction, scoreGap < 2.5 {
            return true
        }
        if deltaGap >= max(40, best.deltaY / 3), scoreGap < 1.4 {
            return true
        }
        if deltaGap >= max(28, best.deltaY / 4), pixelGap < 0.9, best.pixelScore > 8.5 {
            return true
        }
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            let tolerance = max(56, expectedDeltaPixels / 2)
            if abs(best.deltaY - expectedDeltaPixels) > tolerance, scoreGap < 3 {
                return true
            }
        }
        return false
    }

    private func isLikelyBoundaryOrDuplicate(match: Match?, expectedDeltaPixels: Int?) -> Bool {
        guard let match else { return true }
        if hasReliablePixelMotion(match: match, expectedDeltaPixels: expectedDeltaPixels) {
            return false
        }
        let baselineDelta = max(lastMatch?.deltaY ?? 0, expectedDeltaPixels ?? 0)
        let suspiciousDeltaCeiling = max(18, min(36, max(baselineDelta / 2, (lastMatch?.deltaY ?? 0) / 3)))
        return confidence(for: match) < 0.84 || match.deltaY <= suspiciousDeltaCeiling
    }

    private func hasReliablePixelMotion(match: Match?, expectedDeltaPixels: Int?) -> Bool {
        guard let match else { return false }
        let baselineDelta = max(lastMatch?.deltaY ?? 0, expectedDeltaPixels ?? 0)
        let minimumMotion = max(18, min(36, max(baselineDelta / 2, (lastMatch?.deltaY ?? 0) / 3)))
        let strongBandRatio = Double(match.strongBandCount) / Double(max(1, match.bandCount))
        let followsExpectedMovement = expectedDeltaPixels.map {
            abs(match.deltaY - $0) <= max(12, $0 / 5)
        } ?? false
        let normalEvidence = match.pixelScore <= 3
            && match.totalScore <= 18
            && strongBandRatio >= 0.7
        let expectedEvidence = followsExpectedMovement
            && match.pixelScore <= 3
            && match.totalScore <= 26
            && strongBandRatio >= 0.5
        return match.deltaY > minimumMotion
            && (normalEvidence || expectedEvidence)
    }

    private func confidence(for match: Match) -> Double {
        let pixelComponent = max(0, 1 - match.pixelScore / 20)
        let totalComponent = max(0, 1 - match.totalScore / 32)
        let strongBandComponent = Double(match.strongBandCount) / Double(max(1, match.bandCount))
        let variancePenalty = min(1, match.bandVariance / 30)
        return min(1, max(0, pixelComponent * 0.4 + totalComponent * 0.3 + strongBandComponent * 0.2 + (1 - variancePenalty) * 0.1))
    }
}
