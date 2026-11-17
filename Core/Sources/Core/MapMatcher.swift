import Foundation

/// One run of consecutive points matched to one way: from `fromM` to `toM` metres along it, points `first...last` of the trip.
public struct MatchedStretch: Sendable, Equatable, Codable {
    public var seq: Int
    public var wayId: Int64
    public var fromM, toM: Double
    public var confidence: Double   // 0...1; below MapMatcher.confident the map shows the recorded line
    public var first, last: Int
    public init(seq: Int, wayId: Int64, fromM: Double, toM: Double, confidence: Double, first: Int, last: Int) {
        self.seq = seq; self.wayId = wayId; self.fromM = fromM; self.toM = toM; self.confidence = confidence; self.first = first; self.last = last
    }
}
