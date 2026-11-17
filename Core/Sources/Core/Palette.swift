import Foundation

/// A colour as 0xRRGGBB for light and dark appearance, tuned separately (never inverted).
public struct Hex: Sendable, Equatable {
    public let light: UInt32, dark: UInt32
    public init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }
}

/// LifePath's colours: warm paper surfaces and retro-print accents (stage 6 design spec, section 1).
public enum Palette {
    public static let page = Hex(light: 0xFAFAF9, dark: 0x141414)
    public static let card = Hex(light: 0xEDECE8, dark: 0x222222)
    public static let inset = Hex(light: 0xE1DFDA, dark: 0x2E2E2E)
    public static let text = Hex(light: 0x1C1C1E, dark: 0xEDEDEC)
    public static let muted = Hex(light: 0x5C5E63, dark: 0xA6A6A3)
    public static let satsuma = Hex(light: 0xC4521A, dark: 0xF08C4E)
    public static let cherry = Hex(light: 0xB2362C, dark: 0xE86A5B)
    public static let mustard = Hex(light: 0xB07D12, dark: 0xE7B547)
    public static let unsure = Hex(light: 0x8E8E93, dark: 0x8E8E93)

    public static func mode(_ m: TravelMode) -> Hex {
        switch m {
        case .walk: satsuma
        case .run: cherry
        case .bike: Hex(light: 0x5A842C, dark: 0x9DC46A)
        case .car: Hex(light: 0x87573A, dark: 0xC99772)
        case .bus: mustard
        case .tram: Hex(light: 0x227A72, dark: 0x5DB8AC)
        case .train: Hex(light: 0x3A69AE, dark: 0x82A8E2)
        case .boat: Hex(light: 0x4E8FB8, dark: 0x7FB7DA)
        }
    }

    /// Line colour by age: 0 newest (mustard), 0.5 satsuma, 1 oldest (cherry); full strength, linear in sRGB.
    public static func dateRamp(_ f: Double) -> (light: UInt32, dark: UInt32) {
        let f = min(1, max(0, f))
        let (a, b, t) = f < 0.5 ? (mustard, satsuma, f * 2) : (satsuma, cherry, f * 2 - 1)
        return (mix(a.light, b.light, t), mix(a.dark, b.dark, t))
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        (0..<3).reduce(0) { acc, k in
            let s = UInt32(16 - 8 * k)
            let x = Double((a >> s) & 0xFF), y = Double((b >> s) & 0xFF)
            return acc | UInt32((x + (y - x) * t).rounded()) << s
        }
    }

    /// WCAG 2 contrast ratio between two colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            [16, 8, 0].map { s -> Double in
                let v = Double((c >> UInt32(s)) & 0xFF) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }.enumerated().map { [0.2126, 0.7152, 0.0722][$0.offset] * $0.element }.reduce(0, +)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
