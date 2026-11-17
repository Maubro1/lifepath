import Foundation

public struct SegmentHit: Hashable, Sendable {
    public var wayId: Int64; public var seg: Int; public var bike: Bool
    public init(wayId: Int64, seg: Int, bike: Bool) { self.wayId = wayId; self.seg = seg; self.bike = bike }
}

public struct CoverageResult: Sendable, Equatable {
    public var ways: [Int64: Bool]   // covered way -> true when covered only with cycling
    public var onFoot: Int; public var withBike: Int; public var total: Int
    public init(ways: [Int64: Bool], onFoot: Int, withBike: Int, total: Int) {
        self.ways = ways; self.onFoot = onFoot; self.withBike = withBike; self.total = total
    }
}
