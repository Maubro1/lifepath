import XCTest
@testable import Core

final class TransitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ east: Double, _ north: Double = 0) -> (lat: Double, lon: Double) { Geo.offset(lat: 52, lon: 5, north: north, east: east) }

    /// A straight east-west line with stops every 2 km from 0 to 10 km.
    func line(_ id: Int64, _ mode: TravelMode = .train, north: Double = 0, reversed: Bool = false) -> Route {
        var stops = (0...5).map { k in Route.Stop(id: id * 100 + Int64(k), lat: at(Double(k) * 2000, north).lat, lon: at(Double(k) * 2000, north).lon) }
        var path = stride(from: 0.0, through: 10_000, by: 250).map { at($0, north) }
        if reversed { stops.reverse(); path.reverse() }
        return Route(id: id, mode: mode, stops: stops, path: path)
    }

    /// A ride east from `from` to `to` metres, fixes every 10 s at 25 m/s with `offset` north of the track; `gap` drops fixes between.
    func ride(_ from: Double, _ to: Double, offset: Double = 15, gap: ClosedRange<Double>? = nil) -> [FilteredPoint] {
        stride(from: from, through: to, by: 250).enumerated().compactMap { i, e in
            if let gap, gap.contains(e) { return nil }
            let p = at(e, offset)
            return FilteredPoint(t: t0 + Double(i) * 10, lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: 20, speed: 25, kind: .moving)
        }
    }

    func testMatchesOrderedStops() throws {
        let m = try XCTUnwrap(Transit.match(ride(2000, 8000), routes: [line(1)]))
        XCTAssertEqual(m.route.id, 1)
        XCTAssertEqual(m.from, 1); XCTAssertEqual(m.to, 4)
        // The drawn path is the track between the two stations: on the line, from 2 to 8 km.
        XCTAssertTrue(m.path.allSatisfy { abs(Geo.distance($0.lat, $0.lon, 52, $0.lon)) < 1 })
        XCTAssertLessThan(Geo.distance(m.path[0].lat, m.path[0].lon, at(2000).lat, at(2000).lon), 10)
        XCTAssertLessThan(Geo.distance(m.path.last!.lat, m.path.last!.lon, at(8000).lat, at(8000).lon), 10)
    }

    func testOppositeDirectionRejected() {
        // The same stations in the other order: a relation for the other direction does not match.
        XCTAssertNil(Transit.match(ride(2000, 8000), routes: [line(1, reversed: true)]))
    }

    func testOffTrackRejected() {
        // Fixes 400 m away from the track (a motorway beside it) are not this train.
        XCTAssertNil(Transit.match(ride(2000, 8000, offset: 400), routes: [line(1)]))
    }

    func testSharedTrackPicksStopsPassed() throws {
        // Two lines on one track; the express stops only at the ends, the local one at every station. A ride that halts
        // nowhere between still fits both; the one whose path matches is chosen, never nil for identical tracks.
        let express = Route(id: 2, mode: .train, stops: [line(1).stops[1], line(1).stops[4]], path: line(1).path)
        let m = try XCTUnwrap(Transit.match(ride(2000, 8000), routes: [line(1), express]))
        XCTAssertTrue([1, 2].contains(m.route.id))
    }

    func testSignalGapBetweenStations() throws {
        // A metro: fixes only near the two stations, none in between; ends at stations is enough.
        let m = try XCTUnwrap(Transit.match(ride(2000, 8000, gap: 2300...7700), routes: [line(3, .train)]))
        XCTAssertEqual(m.from, 1); XCTAssertEqual(m.to, 4)
    }

    func testBusNeedsCloseStops() {
        // A bus route's stops are 40 m wide: a ride starting 150 m from the stop is not this bus.
        let bus = line(4, .bus)
        XCTAssertNil(Transit.match(ride(2150, 8000, offset: 5), routes: [bus]))
        XCTAssertNotNil(Transit.match(ride(2000, 8000, offset: 5), routes: [bus]))
    }

    func testParseRoutesIndexAndGeometry() throws {
        let index = """
        {"elements":[{"type":"relation","id":7,"tags":{"type":"route","route":"train","name":"Utrecht - Amersfoort"},
          "members":[{"type":"node","ref":11,"role":"stop"},{"type":"way","ref":21,"role":""}]}]}
        """
        let i = try OSM.parseRoutes(Data(index.utf8))
        XCTAssertEqual(i.missing, [7]); XCTAssertTrue(i.routes.isEmpty)
        let geom = """
        {"elements":[{"type":"relation","id":7,"tags":{"type":"route","route":"train"},
          "members":[
            {"type":"node","ref":11,"role":"stop","lat":52.0,"lon":5.0},
            {"type":"node","ref":12,"role":"platform","lat":52.0,"lon":5.1},
            {"type":"node","ref":13,"role":"stop_exit_only","lat":52.0,"lon":5.2},
            {"type":"way","ref":22,"role":"","geometry":[{"lat":52.0,"lon":5.2},{"lat":52.0,"lon":5.1}]},
            {"type":"way","ref":21,"role":"","geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.1}]}]}]}
        """
        let g = try OSM.parseRoutes(Data(geom.utf8))
        let r = try XCTUnwrap(g.routes.first)
        XCTAssertEqual(r.mode, .train)
        XCTAssertEqual(r.stops.map(\.id), [11, 13])                 // stop roles; platforms only when a route has no stops
        XCTAssertEqual(r.path.first?.lon, 5.0); XCTAssertEqual(r.path.last?.lon, 5.2)   // ways joined end to end, reversed as needed
        XCTAssertEqual(r.path.count, 3)
    }

    func testStretchAlongTrack() throws {
        let r = line(1)
        let m = try XCTUnwrap(Transit.match(ride(2000, 8000), routes: [r]))
        let s = Transit.stretch(m.route, from: m.from, to: m.to, start: t0, end: t0 + 240)
        XCTAssertEqual(s.wayId, -1)
        XCTAssertEqual(s.fromM, 2000, accuracy: 5); XCTAssertEqual(s.toM, 8000, accuracy: 5)
        XCTAssertEqual(s.confidence, 1)
    }
}
