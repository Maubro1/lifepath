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

    /// A piece of a ride from `from` to `to` metres, its fixes starting `after` seconds past t0.
    func piece(_ from: Double, _ to: Double, after: Double, walkBefore: Bool = false, walkAfter: Bool = false, joins: Bool = true) -> Transit.Piece {
        Transit.Piece(points: ride(from, to).map { var p = $0; p.t += after; return p }, walkBefore: walkBefore, walkAfter: walkAfter, joins: joins)
    }

    func testRideFromTheFirstStop() {
        // A terminus sits on the track's first vertex: the stretch starts at 0 m instead of trapping.
        let s = Transit.stretch(line(1), from: 0, to: 2, start: t0, end: t0 + 300)
        XCTAssertEqual(s.fromM, 0); XCTAssertEqual(s.toM, 4000, accuracy: 1)
    }

    func testLinksPiecesAcrossAGap() throws {
        // Boarded at 2 km, no signal from 4.5 to 6 km for 5 minutes, alighted at 8 km: one ride, drawn without a gap.
        let out = Transit.link([piece(2000, 4500, after: 0, walkBefore: true), piece(6000, 8000, after: 400, walkAfter: true)], routes: [line(1)])
        XCTAssertEqual(out.map(\.piece), [0, 1])
        XCTAssertEqual(out[0].stretch.fromM, 2000, accuracy: 1)
        XCTAssertEqual(out[0].stretch.toM, out[1].stretch.fromM, accuracy: 1e-9)   // the first share runs on across the gap
        XCTAssertEqual(out[1].stretch.toM, 8000, accuracy: 1)
        XCTAssertEqual(out[0].stretch.wayId, -1)
    }

    func testStationPassedAtSpeedIsNoEnd() throws {
        // The second piece ends right at the 6 km station without stopping: the ride runs on to 8 km.
        let out = Transit.link([piece(2000, 4500, after: 0, walkBefore: true), piece(4750, 6000, after: 200),
                                piece(6250, 8000, after: 300, walkAfter: true)], routes: [line(1)])
        XCTAssertEqual(out.map(\.piece), [0, 1, 2])
        XCTAssertEqual(out[2].stretch.toM, 8000, accuracy: 1)
    }

    func testPieceSnappedOnABlipIsRelinked() throws {
        // The first piece alone runs station to station (1 to 3), but passes the 6 km station at speed: it joins the next piece.
        let out = Transit.link([piece(2000, 6000, after: 0, walkBefore: true), piece(6250, 8000, after: 200, walkAfter: true)], routes: [line(1)])
        XCTAssertEqual(out.map(\.piece), [0, 1])
        XCTAssertEqual(out[1].stretch.toM, 8000, accuracy: 1)
        // A piece settled at both ends is its own ride; the next one, starting 250 m past the station, stays unsnapped.
        XCTAssertEqual(Transit.link([piece(2000, 6000, after: 0, walkBefore: true, walkAfter: true), piece(6250, 8000, after: 200, walkAfter: true)],
                                    routes: [line(1)]).map(\.piece), [0])
    }

    func testRoughEndsAnchoredOnThePlatform() throws {
        // The ride's first and last fixes are 400 m past the stations (rough, late); you stood on the platforms just before and after.
        var p = piece(2400, 7600, after: 60)
        let at = { (e: Double, t: Double) -> FilteredPoint in
            let c = self.at(e, 5); return FilteredPoint(t: self.t0 + t, lat: c.lat, lon: c.lon, rawLat: c.lat, rawLon: c.lon, hAcc: 10, speed: 0, kind: .still)
        }
        p.lead = at(2000, 0); p.tail = at(8000, 400)
        let out = Transit.link([p], routes: [line(1)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].stretch.fromM, 2000, accuracy: 1)
        XCTAssertEqual(out[0].stretch.toM, 8000, accuracy: 1)
        XCTAssertEqual(out[0].stretch.start, p.points[0].t)   // shares keep the trip's own times, so the line finds them
        XCTAssertTrue(Transit.link([piece(2400, 7600, after: 60)], routes: [line(1)]).isEmpty)   // without anchors: no station near either end
    }

    func testImpossibleGapOrStayIsNotLinked() {
        // 1.5 km further only 1 s later is no train; a stay between pieces (joins false) ends the chain.
        XCTAssertTrue(Transit.link([piece(2000, 4500, after: 0, walkBefore: true), piece(7000, 8000, after: 101, walkAfter: true)],
                                   routes: [line(1)]).isEmpty)
        XCTAssertTrue(Transit.link([piece(2000, 4500, after: 0, walkBefore: true), piece(6000, 8000, after: 400, walkAfter: true, joins: false)],
                                   routes: [line(1)]).isEmpty)
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

    func testParseRoutesJoinsUnevenWays() throws {
        // Three ways of 3, 4 and 2 vertices; the first points away from the second, the third is stored backwards.
        let geom = """
        {"elements":[{"type":"relation","id":8,"tags":{"type":"route","route":"tram"},
          "members":[
            {"type":"node","ref":1,"role":"stop","lat":52.0,"lon":5.0},
            {"type":"node","ref":2,"role":"stop","lat":52.0,"lon":5.6},
            {"type":"way","ref":31,"role":"","geometry":[{"lat":52.0,"lon":5.2},{"lat":52.0,"lon":5.1},{"lat":52.0,"lon":5.0}]},
            {"type":"way","ref":32,"role":"","geometry":[{"lat":52.0,"lon":5.2},{"lat":52.0,"lon":5.3},{"lat":52.0,"lon":5.4},{"lat":52.0,"lon":5.5}]},
            {"type":"way","ref":33,"role":"","geometry":[{"lat":52.0,"lon":5.6},{"lat":52.0,"lon":5.5}]}]}]}
        """
        let r = try XCTUnwrap(OSM.parseRoutes(Data(geom.utf8)).routes.first)
        XCTAssertEqual(r.path.map(\.lon), [5.0, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6])   // one run east, no back-and-forth
    }
}
