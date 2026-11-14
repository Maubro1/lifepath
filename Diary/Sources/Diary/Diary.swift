import Foundation
import GRDB
import Core

public final class Diary: Sendable {
    public init(path: String) throws {}
    public static func defaultPath() throws -> String { "" }
    public func append(_ points: [FilteredPoint]) throws {}
    public func log(_ events: [LoggedEvent]) throws {}
    public func lastPoint() throws -> FilteredPoint? { nil }
    public func points(from: Date, to: Date) throws -> [FilteredPoint] { [] }
    public func events(from: Date, to: Date) throws -> [LoggedEvent] { [] }
    public func pruneEvents(olderThan: Date) throws {}
}
