import Core
import Diary
import SwiftUI

/// Number formats shared by the Timeline and Stats screens: the locale's separators, metric units.
enum Format {
    static func distance(_ m: Double) -> String {
        Measurement(value: m / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// Under a minute but moving still reads "< 1 min", never "0 min" or nothing.
    static func duration(_ s: TimeInterval) -> String {
        if s < 60 { return "< 1 min" }
        return Duration.seconds(Int(s)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "yyyy-MM-dd" keys are Gregorian; the date is that day's start in the current calendar.
    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = Calendar.current.timeZone
        return g.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// Days newest first. Reads the small `day` table off the main actor, only while on screen.
struct TimelineScreen: View {
    @State private var days: [(summary: DaySummary, steps: Int?)] = []
    @State private var loaded = false
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool { onScreen && scenePhase == .active }

    var body: some View {
        NavigationStack {
            List {
                if loaded && days.isEmpty {
                    Text("No days yet. Days appear here once LifePath has recorded.")
                }
                ForEach(days, id: \.summary.day) { DayCard(summary: $0.summary, steps: $0.steps) }
            }
            .navigationTitle("Timeline")
            .refreshable {
                if let diary = Recorder.shared.readDiary { await DayService.run(diary) }
                await load()
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in if v { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: DayService.changed)) { _ in if visible { Task { await load() } } }
    }

    private func load() async {
        guard let diary = Recorder.shared.readDiary else { return }   // locked before first unlock
        let read = await Task.detached(priority: .userInitiated) { try? diary.days() }.value
        if let read { days = read; loaded = true }
    }
}

private struct DayCard: View {
    let summary: DaySummary
    let steps: Int?
    @State private var lines: [[(lat: Double, lon: Double)]] = []

    private var date: Date? { Format.date(summary.day) }
    private var moving: Bool { summary.distance > 0 || summary.movingTime > 0 }
    private var title: String { date?.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) ?? summary.day }

    private var label: String {
        var p = [title]
        if moving { p += [Format.distance(summary.distance), "\(Format.duration(summary.movingTime)) moving"] } else { p.append("No trips") }
        if let steps { p.append("\(steps.formatted()) steps") }
        return p.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RouteDrawing(lines: lines)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if moving {
                    Text("\(Format.distance(summary.distance)) · \(Format.duration(summary.movingTime))")
                } else { Text("No trips").foregroundStyle(.secondary) }
                if let steps { Text("\(steps.formatted()) steps").foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .task(id: summary.day) {
            guard let from = date, let to = Calendar.current.date(byAdding: .day, value: 1, to: from),
                  let diary = Recorder.shared.readDiary else { return }
            let read = await Task.detached(priority: .utility) { try? diary.tripLines(from: from, to: to) }.value
            lines = (read ?? []).map { $0.coords.map { (lat: $0.lat, lon: $0.lon) } }
        }
    }
}

/// The day's trip lines as a plain line: equirectangular, longitude scaled by cos(mid-latitude), aspect kept, 4 pt inset.
private struct RouteDrawing: View {
    let lines: [[(lat: Double, lon: Double)]]

    var body: some View {
        Canvas { ctx, size in
            let all = lines.joined()
            guard let first = all.first else { return }
            var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
            for c in all { minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat); minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon) }
            let k = cos((minLat + maxLat) / 2 * .pi / 180)
            let w = (maxLon - minLon) * k, h = maxLat - minLat   // degrees of latitude
            if max(w, h) * 111_320 < 1 {
                ctx.fill(Path(ellipseIn: CGRect(x: size.width / 2 - 2, y: size.height / 2 - 2, width: 4, height: 4)), with: .color(.primary))
                return
            }
            let scale = (size.width - 8) / max(w, h), dx = (size.width - w * scale) / 2, dy = (size.height - h * scale) / 2
            func pt(_ c: (lat: Double, lon: Double)) -> CGPoint {
                CGPoint(x: dx + (c.lon - minLon) * k * scale, y: size.height - dy - (c.lat - minLat) * scale)
            }
            for line in lines where !line.isEmpty {
                var path = Path()
                path.move(to: pt(line[0]))
                for c in line.dropFirst() { path.addLine(to: pt(c)) }
                ctx.stroke(path, with: .color(.primary), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}
