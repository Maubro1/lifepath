import XCTest
#if canImport(FoundationXML)
import FoundationXML   // XMLParser lives here off Apple platforms
#endif
@testable import Core

final class ExportTests: XCTestCase {
    /// kinds: m moving, r rough; points 10 s apart with millisecond timestamps.
    func trip(_ kinds: String, base: Double = 1_700_000_000.123) -> Trip {
        let pts: [FilteredPoint] = kinds.enumerated().map { (i: Int, c: Character) -> FilteredPoint in
            FilteredPoint(t: Date(timeIntervalSince1970: base + Double(i) * 10), lat: 50.1 + Double(i) * 0.001, lon: 4.2 + Double(i) * 0.002,
                          rawLat: 0, rawLon: 0, hAcc: 5, speed: 1, kind: c == "r" ? .rough : .moving)
        }
        return Trip(points: pts, start: pts[0].t, end: pts[pts.count - 1].t, distance: 1, movingTime: 1)
    }

    final class Collector: NSObject, XMLParserDelegate {
        var counts: [String: Int] = [:]
        var firstAttrs: [String: String]?
        var firstText: [String: String] = [:]
        var current = ""
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            counts[name, default: 0] += 1; current = name
            if name == "trkpt", firstAttrs == nil { firstAttrs = a }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if firstText[current] == nil { firstText[current] = s } }
    }

    func parse(_ s: String) -> Collector {
        let c = Collector(); let p = XMLParser(data: Data(s.utf8)); p.delegate = c
        XCTAssertTrue(p.parse(), "\(String(describing: p.parserError))")
        return c
    }

    func testRoughBreaksSegment() {
        let segs = Export.segments(trip("mmrrmm"))
        XCTAssertEqual(segs.map { $0.count }, [2, 2])
        XCTAssertFalse(segs.joined().contains { $0.kind == .rough })
    }

    func testShortSegmentDropped() {
        XCTAssertEqual(Export.segments(trip("mrmm")).count, 1)
        XCTAssertEqual(Export.segments(trip("mrmm"))[0][0].lat, 50.1 + 0.002, accuracy: 1e-9)
        XCTAssertEqual(Export.segments(trip("mrm")).count, 0)
        XCTAssertEqual(Export.trip(trip("mrm"), .gpx, first: true), "")
    }

    func testGPXParsesAndKeepsEveryPoint() throws {
        let a = trip("mmm"), b = trip("mmmm", base: 1_700_001_000)
        let s = Export.head(.gpx) + Export.trip(a, .gpx, first: true) + Export.trip(b, .gpx, first: false) + Export.tail(.gpx)
        let c = parse(s)
        XCTAssertEqual(c.counts["trkpt"], 7)
        XCTAssertEqual(c.counts["trk"], 2)
        let attrs = try XCTUnwrap(c.firstAttrs)
        XCTAssertEqual(Double(attrs["lat"]!)!, a.points[0].lat, accuracy: 1e-7)
        XCTAssertEqual(Double(attrs["lon"]!)!, a.points[0].lon, accuracy: 1e-7)
        let t = try Date(c.firstText["time"]!, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        XCTAssertEqual(t.timeIntervalSince(a.points[0].t), 0, accuracy: 0.001)
    }

    func testGeoJSONLonLatOrderAndCommas() throws {
        let a = trip("mmm"), mid = trip("mrm"), c = trip("mm", base: 1_700_001_000)
        var s = Export.head(.geojson), first = true
        for t in [a, mid, c] {
            let part = Export.trip(t, .geojson, first: first)
            if !part.isEmpty { first = false; s += part }
        }
        s += Export.tail(.geojson)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        let feats = try XCTUnwrap(root["features"] as? [[String: Any]])
        XCTAssertEqual(feats.count, 2)
        let geo = try XCTUnwrap(feats[0]["geometry"] as? [String: Any])
        let coords = try XCTUnwrap(geo["coordinates"] as? [[[Double]]])
        XCTAssertEqual(coords[0][0][0], a.points[0].lon, accuracy: 1e-7)
        XCTAssertEqual(coords[0][0][1], a.points[0].lat, accuracy: 1e-7)
        let times = try XCTUnwrap((feats[0]["properties"] as? [String: Any])?["coordTimes"] as? [[String]])
        XCTAssertEqual(times.map { $0.count }, coords.map { $0.count })
    }

    func testKMLParsesWhenMatchesCoord() {
        let a = trip("mmrmm")
        let c = parse(Export.head(.kml) + Export.trip(a, .kml, first: true) + Export.tail(.kml))
        XCTAssertEqual(c.counts["when"], 4)
        XCTAssertEqual(c.counts["gx:coord"], 4)
        XCTAssertEqual(c.counts["gx:Track"], 2)
        XCTAssertEqual(c.firstText["gx:coord"], String(format: "%.7f %.7f 0", a.points[0].lon, a.points[0].lat))
    }
}
