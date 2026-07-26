import Foundation

struct LongScreenshotRetryPolicy {
    private let delays: [TimeInterval]

    init(delays: [TimeInterval] = [0.10, 0.18, 0.30, 0.48]) {
        self.delays = delays
    }

    var maximumRetryCount: Int {
        delays.count
    }

    func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}
