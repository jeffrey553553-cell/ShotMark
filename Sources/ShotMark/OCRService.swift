import CoreGraphics
import Foundation
import Vision

enum OCRServiceError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有识别到文字。"
        }
    }
}

final class OCRService {
    func recognizeText(in image: CGImage, completion: @escaping (Result<[OCRLine], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string, boundingBox: observation.boundingBox)
                }

                completion(lines.isEmpty ? .failure(OCRServiceError.noText) : .success(lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}
