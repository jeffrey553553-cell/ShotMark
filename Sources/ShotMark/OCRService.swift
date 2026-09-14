import CoreGraphics
import Foundation
import Vision

enum OCRServiceError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有识别到文字、二维码或条码。"
        }
    }
}

final class OCRService {
    func recognizeContent(
        in image: CGImage,
        completion: @escaping (Result<OCRRecognitionResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true

            let barcodeRequest = VNDetectBarcodesRequest()
            barcodeRequest.symbologies = [
                .qr, .aztec, .dataMatrix, .pdf417, .code128, .ean13, .ean8, .upce
            ]

            do {
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                try handler.perform([textRequest, barcodeRequest])
                let lines = (textRequest.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string, boundingBox: observation.boundingBox)
                }
                var seenPayloads = Set<String>()
                let codes = (barcodeRequest.results ?? []).compactMap { observation -> OCRDetectedCode? in
                    guard let payload = observation.payloadStringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !payload.isEmpty,
                        seenPayloads.insert(payload).inserted
                    else { return nil }
                    return OCRDetectedCode(
                        payload: payload,
                        symbology: observation.symbology,
                        boundingBox: observation.boundingBox
                    )
                }
                let result = OCRRecognitionResult(lines: lines, codes: codes)
                completion(result.isEmpty ? .failure(OCRServiceError.noText) : .success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
