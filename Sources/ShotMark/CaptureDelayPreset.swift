import Foundation

enum CaptureDelayPreset: Int, CaseIterable, Equatable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    var title: String {
        "\(rawValue) 秒"
    }
}
