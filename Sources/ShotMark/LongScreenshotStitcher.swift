import CoreGraphics
import Foundation

enum LongScreenshotStitchDirection {
    case unresolved
    case downward
    case upward
}

enum LongScreenshotStitchOutcome {
    case initialized
    case appended(deltaY: Int)
    case ignoredNoMovement
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
        let startRow: Int
        let rowCount: Int
    }

    private struct OverlapMetrics {
        let averageDifference: Double
        let strongBandCount: Int
        let bandCount: Int
        let worstDifference: Double
        let variance: Double
    }

    private struct Match {
        let direction: LongScreenshotStitchDirection
        let deltaY: Int
        let pixelScore: Double
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

    private(set) var acceptedFrameCount = 0

    var outputHeight: Int {
        contentSlices.reduce(0) { $0 + $1.rowCount }
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
        acceptedFrameCount = 0
    }

    func append(_ image: CGImage, expectedDeltaPixels: Int? = nil, maxOutputHeight: Int = 120_000) -> LongScreenshotStitchUpdate? {
        guard let raster = RasterImage(cgImage: image) else { return nil }
        guard let lastRaster, let baseRaster else {
            self.baseRaster = raster
            self.lastRaster = raster
            contentSlices = [ContentSlice(raster: raster, startRow: 0, rowCount: raster.height)]
            stitchDirection = .unresolved
            lastMatch = nil
            cachedMergedImage = image
            acceptedFrameCount = 1
            return update(outcome: .initialized, mergedImage: image, confidence: 1)
        }

        guard raster.width == lastRaster.width, raster.height == lastRaster.height else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        let topBand = headerHeight == 0 ? detectStaticBand(previous: lastRaster, current: raster, fromTop: true) : headerHeight
        let bottomBand = footerHeight == 0 ? detectStaticBand(previous: lastRaster, current: raster, fromTop: false) : footerHeight
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

        let match = bestMatch(
            previous: lastRaster,
            current: raster,
            headerHeight: topBand,
            footerHeight: bottomBand,
            leadingStaticWidth: leftBand,
            trailingStaticWidth: rightBand,
            expectedDeltaPixels: expectedDeltaPixels
        )

        if frameDifference < 8.5, isLikelyBoundaryOrDuplicate(match: match, expectedDeltaPixels: expectedDeltaPixels) {
            return update(outcome: .ignoredNoMovement, confidence: 1)
        }

        guard let match, isAcceptable(match, expectedDeltaPixels: expectedDeltaPixels) else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        if stitchDirection == .unresolved {
            stitchDirection = match.direction
            headerHeight = topBand
            footerHeight = bottomBand
            leadingStaticWidth = leftBand
            trailingStaticWidth = rightBand
            bootstrapBaseContent(from: baseRaster)
        }

        let remainingHeight = maxOutputHeight - outputHeight
        guard remainingHeight > 0 else {
            return update(outcome: .ignoredAlignmentFailed, confidence: confidence(for: match))
        }

        let acceptedDelta = min(match.deltaY, remainingHeight)
        guard let startRow = sliceStartRow(for: match.direction, in: raster, deltaY: acceptedDelta) else {
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        let slice = ContentSlice(raster: raster, startRow: startRow, rowCount: acceptedDelta)
        switch match.direction {
        case .downward:
            contentSlices.append(slice)
        case .upward:
            contentSlices.insert(slice, at: 0)
        case .unresolved:
            return update(outcome: .ignoredAlignmentFailed, confidence: 0)
        }

        self.lastRaster = raster
        self.lastMatch = match
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
        for slice in contentSlices {
            slice.raster.copyRows(startRow: slice.startRow, rowCount: slice.rowCount, into: &pixels, destinationRow: destinationRow)
            destinationRow += slice.rowCount
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

    private func update(outcome: LongScreenshotStitchOutcome, mergedImage: CGImage? = nil, confidence: Double) -> LongScreenshotStitchUpdate {
        LongScreenshotStitchUpdate(
            outcome: outcome,
            mergedImage: mergedImage ?? self.mergedImage(),
            acceptedFrameCount: acceptedFrameCount,
            outputHeight: outputHeight,
            direction: stitchDirection,
            confidence: confidence
        )
    }

    private func bootstrapBaseContent(from raster: RasterImage) {
        let startRow = headerHeight
        let rowCount = max(1, raster.height - headerHeight - footerHeight)
        contentSlices = [ContentSlice(raster: raster, startRow: startRow, rowCount: rowCount)]
        cachedMergedImage = nil
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

    private func detectStaticBand(previous: RasterImage, current: RasterImage, fromTop: Bool) -> Int {
        let maxBand = min(previous.height / 5, 160)
        let step = max(2, min(8, previous.height / 180))
        let xInset = max(12, previous.width / 20)
        let xStart = xInset
        let xEnd = max(xStart + 1, previous.width - xInset)
        let columnStride = max(2, (xEnd - xStart) / 48)
        var bandHeight = 0

        for offset in stride(from: 0, to: maxBand, by: step) {
            let row = fromTop ? offset : previous.height - 1 - offset
            let difference = previous.blockDifference(
                comparedTo: current,
                startRow: row,
                otherStartRow: row,
                rowCount: 1,
                xStart: xStart,
                xEnd: xEnd,
                columnStride: columnStride,
                rowStride: 1
            )
            if difference < 5 {
                bandHeight = offset + step
            } else if offset > step * 2 {
                break
            }
        }

        return min(max(0, bandHeight), maxBand)
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
        guard contentHeight > 24, let xBounds = matchingColumnBounds(width: previous.width, leadingStaticWidth: leadingStaticWidth, trailingStaticWidth: trailingStaticWidth) else {
            return 255
        }

        let bandHeight = max(12, min(24, contentHeight / 8))
        let columnStride = max(2, (xBounds.upperBound - xBounds.lowerBound) / 72)
        var total = 0.0
        let bandCount = 8
        for index in 0..<bandCount {
            let ratio = Double(index + 1) / Double(bandCount + 1)
            let row = headerHeight + min(max(0, contentHeight - bandHeight), Int(Double(contentHeight - bandHeight) * ratio))
            total += previous.blockDifference(
                comparedTo: current,
                startRow: row,
                otherStartRow: row,
                rowCount: bandHeight,
                xStart: xBounds.lowerBound,
                xEnd: xBounds.upperBound,
                columnStride: columnStride,
                rowStride: 2
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
        expectedDeltaPixels: Int?
    ) -> Match? {
        let contentHeight = previous.height - headerHeight - footerHeight
        guard contentHeight > 48 else { return nil }

        let minDelta = max(12, min(120, contentHeight / 32))
        let minOverlap = max(96, Int(Double(contentHeight) * 0.20))
        let maxDelta = max(minDelta, contentHeight - minOverlap)
        guard maxDelta > minDelta else { return nil }

        let focusedRange = focusedDeltaRange(minDelta: minDelta, maxDelta: maxDelta, expectedDeltaPixels: expectedDeltaPixels)
        var search = searchBestMatch(
            previous: previous,
            current: current,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            leadingStaticWidth: leadingStaticWidth,
            trailingStaticWidth: trailingStaticWidth,
            deltaRange: focusedRange ?? minDelta...maxDelta,
            expectedDeltaPixels: expectedDeltaPixels
        )

        if !isAcceptable(search?.best, expectedDeltaPixels: expectedDeltaPixels) || isAmbiguous(search, expectedDeltaPixels: expectedDeltaPixels) {
            if focusedRange != nil {
                let broad = searchBestMatch(
                    previous: previous,
                    current: current,
                    headerHeight: headerHeight,
                    footerHeight: footerHeight,
                    leadingStaticWidth: leadingStaticWidth,
                    trailingStaticWidth: trailingStaticWidth,
                    deltaRange: minDelta...maxDelta,
                    expectedDeltaPixels: expectedDeltaPixels
                )
                if broad?.best.totalScore ?? .greatestFiniteMagnitude < search?.best.totalScore ?? .greatestFiniteMagnitude {
                    search = broad
                }
            }
        }

        guard let search, isAcceptable(search.best, expectedDeltaPixels: expectedDeltaPixels), !isAmbiguous(search, expectedDeltaPixels: expectedDeltaPixels) else {
            return nil
        }
        return search.best
    }

    private func focusedDeltaRange(minDelta: Int, maxDelta: Int, expectedDeltaPixels: Int?) -> ClosedRange<Int>? {
        var centers: [Int] = []
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            centers.append(min(maxDelta, max(minDelta, expectedDeltaPixels)))
        }
        if let lastMatch {
            centers.append(min(maxDelta, max(minDelta, lastMatch.deltaY)))
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
        expectedDeltaPixels: Int?
    ) -> MatchSearchResult? {
        let contentHeight = previous.height - headerHeight - footerHeight
        let step = max(2, min(10, contentHeight / 160))
        let directions: [LongScreenshotStitchDirection] = stitchDirection == .unresolved ? [.downward, .upward] : [stitchDirection]
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
                coarseCandidates.append(makeMatch(direction: direction, deltaY: delta, metrics: metrics, expectedDeltaPixels: expectedDeltaPixels))
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
            let match = makeMatch(direction: coarseBest.direction, deltaY: delta, metrics: metrics, expectedDeltaPixels: expectedDeltaPixels)
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

    private func makeMatch(direction: LongScreenshotStitchDirection, deltaY: Int, metrics: OverlapMetrics, expectedDeltaPixels: Int?) -> Match {
        let totalScore = metrics.averageDifference
            + consistencyPenalty(for: metrics)
            + priorPenalty(deltaY: deltaY, expectedDeltaPixels: expectedDeltaPixels)
        return Match(
            direction: direction,
            deltaY: deltaY,
            pixelScore: metrics.averageDifference,
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
        guard let xBounds = matchingColumnBounds(width: previous.width, leadingStaticWidth: leadingStaticWidth, trailingStaticWidth: trailingStaticWidth) else { return nil }

        let columnStride = max(2, (xBounds.upperBound - xBounds.lowerBound) / 72)
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
            differences.append(previous.blockDifference(
                comparedTo: current,
                startRow: previousRow,
                otherStartRow: currentRow,
                rowCount: bandHeight,
                xStart: xBounds.lowerBound,
                xEnd: xBounds.upperBound,
                columnStride: columnStride,
                rowStride: 2
            ))
        }

        guard !differences.isEmpty else { return nil }
        let average = differences.reduce(0, +) / Double(differences.count)
        let strongThreshold = max(8.2, min(10.5, average * 0.92))
        let strongBandCount = differences.filter { $0 <= strongThreshold }.count
        let worst = differences.max() ?? average
        let variance = differences.reduce(0.0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(differences.count)
        return OverlapMetrics(
            averageDifference: average,
            strongBandCount: strongBandCount,
            bandCount: differences.count,
            worstDifference: worst,
            variance: variance
        )
    }

    private func matchingColumnBounds(width: Int, leadingStaticWidth: Int, trailingStaticWidth: Int) -> ClosedRange<Int>? {
        let inset = max(8, width / 40)
        let start = min(width - 2, max(inset, leadingStaticWidth + inset))
        let end = max(start + 1, min(width - inset, width - trailingStaticWidth - inset))
        return start < end ? start...end : nil
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

    private func priorPenalty(deltaY: Int, expectedDeltaPixels: Int?) -> Double {
        var penalty = 0.0
        if let expectedDeltaPixels, expectedDeltaPixels > 0 {
            penalty += deviationPenalty(candidate: deltaY, expected: expectedDeltaPixels, weight: 18)
            if deltaY > max(expectedDeltaPixels * 2, expectedDeltaPixels + 180) {
                penalty += 12
            }
        }
        if let lastMatch {
            penalty += deviationPenalty(candidate: deltaY, expected: lastMatch.deltaY, weight: 16)
            if deltaY > max(lastMatch.deltaY * 2, lastMatch.deltaY + 160) {
                penalty += 10
            }
        }
        return penalty
    }

    private func deviationPenalty(candidate: Int, expected: Int, weight: Double) -> Double {
        let baseline = max(1, expected)
        return Double(abs(candidate - expected)) / Double(baseline) * weight
    }

    private func isAcceptable(_ match: Match?, expectedDeltaPixels: Int?) -> Bool {
        guard let match else { return false }
        guard match.pixelScore < 18, match.totalScore < 30 else { return false }
        let requiredStrongBands = max(3, match.bandCount / 2)
        if match.strongBandCount < requiredStrongBands, match.pixelScore > 8.8 {
            return false
        }
        if match.worstBandScore > 28, match.bandVariance > 18 {
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
        let baselineDelta = max(lastMatch?.deltaY ?? 0, expectedDeltaPixels ?? 0)
        let suspiciousDeltaCeiling = max(18, min(36, max(baselineDelta / 2, (lastMatch?.deltaY ?? 0) / 3)))
        return confidence(for: match) < 0.84 || match.deltaY <= suspiciousDeltaCeiling
    }

    private func confidence(for match: Match) -> Double {
        let pixelComponent = max(0, 1 - match.pixelScore / 20)
        let totalComponent = max(0, 1 - match.totalScore / 32)
        let strongBandComponent = Double(match.strongBandCount) / Double(max(1, match.bandCount))
        let variancePenalty = min(1, match.bandVariance / 30)
        return min(1, max(0, pixelComponent * 0.4 + totalComponent * 0.3 + strongBandComponent * 0.2 + (1 - variancePenalty) * 0.1))
    }
}
