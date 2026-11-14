import Foundation

public enum SpeedBand: Sendable, Equatable {
    case walk, bike, drive
    public init(speed: Double) { self = speed < 2.5 ? .walk : speed < 7 ? .bike : .drive }
}

/// Colour maths for the map tab; RGB components in 0...1.
public enum MapColors {
    /// Blue #2F6FDE at 0 → orange #F28C28 at 1, clamped.
    public static func byDate(_ f: Double) -> (r: Double, g: Double, b: Double) {
        let f = min(1, max(0, f))
        func mix(_ a: Double, _ b: Double) -> Double { (a + (b - a) * f) / 255 }
        return (mix(0x2F, 0xF2), mix(0x6F, 0x8C), mix(0xDE, 0x28))
    }

    /// Unknown speeds (< 0) take the median of the known ones, or 0 when none are known.
    public static func filledSpeeds(_ speeds: [Double]) -> [Double] {
        let known = speeds.filter { $0 >= 0 }.sorted()
        let median = known.isEmpty ? 0 : known[known.count / 2]
        return speeds.map { $0 >= 0 ? $0 : median }
    }

    public static func heatAlpha(_ seconds: Double, max maxSeconds: Double) -> Double {
        guard maxSeconds > 0 else { return 0.85 }
        return min(0.85, 0.15 + 0.7 * log(1 + seconds) / log(1 + maxSeconds))
    }
}
