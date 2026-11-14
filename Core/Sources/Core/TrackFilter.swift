import Foundation

public struct TrackFilter: Sendable {
    public var quality: Quality
    public init(quality: Quality) { self.quality = quality }

    public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint? {
        nil
    }

    public mutating func reset() {}
}
