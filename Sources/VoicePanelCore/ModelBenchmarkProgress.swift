import Foundation

public enum ModelBenchmarkProgress {
    public static func recordingFraction(
        elapsed: TimeInterval,
        maximumDuration: TimeInterval
    ) -> Double {
        guard maximumDuration > 0 else { return 0 }
        return min(1, max(0, elapsed / maximumDuration))
    }
}
