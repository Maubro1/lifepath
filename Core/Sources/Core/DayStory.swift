import Foundation

/// One line of a day told as a story: a stay at a place, or a stretch of travel.
public enum StoryItem: Sendable, Equatable {
    case stay(name: String, placeId: Int64?, start: Date, end: Date)
    case trip(mode: TravelMode?, start: Date, end: Date, distance: Double)

    var start: Date { switch self { case .stay(_, _, let s, _), .trip(_, let s, _, _): s } }
}

public enum DayStory {
    /// Stays and trips of the day starting at `day`, in time order, clipped to that day.
    /// A trip splits by its travel-mode stretches; an unnamed place is called after the nearest downloaded street.
    public static func build(day: Date, calendar: Calendar = .current, visits: [Visit], places: [Place], modes: [ModeStretch],
                             lines: [TripLine], nearestStreet: (Double, Double) -> String?) -> [StoryItem] {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let byId = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [StoryItem] = []
        for v in visits where v.end > day && v.start < end {
            let p = v.placeId.flatMap { byId[$0] }
            let name = p?.name ?? p?.pin.flatMap { nearestStreet($0.lat, $0.lon) }.map { "near \($0)" } ?? "A place"
            out.append(.stay(name: name, placeId: v.placeId, start: max(v.start, day), end: min(v.end, end)))
        }
        for l in lines where l.end > day && l.start < end {
            let span = l.end.timeIntervalSince(l.start)
            // shortcut: a stretch's distance is the trip's distance by share of time, upgrade to measured stretch lengths if days show odd splits
            func part(_ a: Date, _ b: Date) -> Double { span > 0 ? l.distance * b.timeIntervalSince(a) / span : l.distance }
            let within = modes.filter { $0.end > l.start && $0.start < l.end }.sorted { $0.start < $1.start }
            if within.isEmpty {
                let a = max(l.start, day), b = min(l.end, end)
                out.append(.trip(mode: nil, start: a, end: b, distance: part(a, b)))
            }
            for m in within {
                let a = max(m.start, l.start, day), b = min(m.end, l.end, end)
                if b > a { out.append(.trip(mode: m.confidence >= TravelModes.confident ? m.mode : nil, start: a, end: b, distance: part(a, b))) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
