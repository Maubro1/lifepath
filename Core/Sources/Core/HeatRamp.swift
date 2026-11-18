import Foundation

/// The heat map's colours: transparent where nothing happened, then mustard, satsuma, cherry and a light core on the
/// most-walked routes (stage 7 spec, section 6).
public enum HeatRamp {
    /// Stops of the ramp: (position, colour 0xRRGGBB, alpha).
    static let stops: [(v: Double, rgb: UInt32, a: Double)] = [
        (0, 0xE7B547, 0), (0.15, 0xE7B547, 0.55), (0.45, 0xF08C4E, 0.8), (0.75, 0xE0503F, 0.92), (1, 0xFFE9C8, 1),
    ]

    /// Colour at `v` in 0...1, linear between stops.
    public static func colour(_ v: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        let v = min(1, max(0, v))
        let k = stops.lastIndex { $0.v <= v } ?? 0, a = stops[k], b = stops[min(k + 1, stops.count - 1)]
        let t = b.v > a.v ? (v - a.v) / (b.v - a.v) : 0
        func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xFF) / 255 }
        func mix(_ s: UInt32) -> Double { ch(a.rgb, s) + (ch(b.rgb, s) - ch(a.rgb, s)) * t }
        return (mix(16), mix(8), mix(0), a.a + (b.a - a.a) * t)
    }

    /// How hot `count` passes are against the diary's busiest spot at this zoom: logarithmic, so one walk already shows
    /// and a daily route still stands out.
    public static func level(count: Double, max: Double) -> Double {
        guard max > 0, count > 0 else { return 0 }
        return min(1, log1p(count) / log1p(max))
    }
}
