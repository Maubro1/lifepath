import Foundation

public enum ExportFormat: String, CaseIterable, Sendable { case gpx, geojson, kml }

/// Trips as GPX, GeoJSON or KML text. Stored positions, rough fixes left out.
public enum Export {
    /// Points in order, broken at every run of rough points (dropped); pieces under 2 points are dropped.
    public static func segments(_ trip: Trip) -> [[FilteredPoint]] {
        var out: [[FilteredPoint]] = [], run: [FilteredPoint] = []
        for p in trip.points {
            if p.kind == .rough { if run.count >= 2 { out.append(run) }; run = [] } else { run.append(p) }
        }
        if run.count >= 2 { out.append(run) }
        return out
    }

    public static func head(_ f: ExportFormat) -> String {
        switch f {
        case .gpx: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"LifePath\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        case .geojson: "{\"type\":\"FeatureCollection\",\"features\":[\n"
        case .kml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\" xmlns:gx=\"http://www.google.com/kml/ext/2.2\"><Document><name>LifePath</name>\n"
        }
    }

    public static func tail(_ f: ExportFormat) -> String {
        switch f { case .gpx: "</gpx>\n"; case .geojson: "]}\n"; case .kml: "</Document></kml>\n" }
    }

    /// `first` is false once a trip was already written (GeoJSON needs the comma).
    public static func trip(_ trip: Trip, _ f: ExportFormat, first: Bool) -> String {
        let segs = segments(trip)
        if segs.isEmpty { return "" }
        let name = time(trip.start)   // ISO time: nothing to escape in XML or JSON
        var s = ""
        switch f {
        case .gpx:
            s = "<trk><name>\(name)</name>"
            for seg in segs {
                s += "<trkseg>" + seg.map { "<trkpt lat=\"\(num($0.lat))\" lon=\"\(num($0.lon))\"><time>\(time($0.t))</time></trkpt>" }.joined() + "</trkseg>"
            }
            s += "</trk>\n"
        case .geojson:
            let coords = segs.map { "[" + $0.map { "[\(num($0.lon)),\(num($0.lat))]" }.joined(separator: ",") + "]" }.joined(separator: ",")
            let times = segs.map { "[" + $0.map { "\"\(time($0.t))\"" }.joined(separator: ",") + "]" }.joined(separator: ",")
            s = (first ? "" : ",\n") + "{\"type\":\"Feature\",\"geometry\":{\"type\":\"MultiLineString\",\"coordinates\":[\(coords)]},\"properties\":{\"start\":\"\(name)\",\"end\":\"\(time(trip.end))\",\"coordTimes\":[\(times)]}}"
        case .kml:
            s = "<Placemark><name>\(name)</name><gx:MultiTrack>"
            for seg in segs {
                s += "<gx:Track>" + seg.map { "<when>\(time($0.t))</when>" }.joined() + seg.map { "<gx:coord>\(num($0.lon)) \(num($0.lat)) 0</gx:coord>" }.joined() + "</gx:Track>"
            }
            s += "</gx:MultiTrack></Placemark>\n"
        }
        return s
    }

    private static func num(_ v: Double) -> String { String(format: "%.7f", v) }
    private static func time(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
}
