import Foundation

public struct HealthInput: Sendable {
    public var now: Date
    public var events: [LoggedEvent]
    public var points: [FilteredPoint]
    public var settings: [String: String]
    public init(now: Date, events: [LoggedEvent], points: [FilteredPoint], settings: [String: String]) {
        self.now = now; self.events = events; self.points = points; self.settings = settings
    }
}

public enum HealthReport {
    // Deterministic: only input.now, a gregorian calendar in the current time zone.
    // shortcut: day starts + h hours, so a DST day shows 24 rows with one shifted; fine for a diagnostic.
    public static func render(_ input: HealthInput, days: Int = 3) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone.current
        func fmt(_ p: String) -> DateFormatter {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = cal; f.timeZone = cal.timeZone
            f.dateFormat = p; return f
        }
        let full = fmt("yyyy-MM-dd HH:mm"), day = fmt("yyyy-MM-dd"), hm = fmt("HH:mm")
        let events = input.events.sorted { $0.t < $1.t }
        let points = input.points.sorted { $0.t < $1.t }
        let today = cal.startOfDay(for: input.now)
        let first = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: today)!
        let thermalRank = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]
        // Returns to Still and leaving decisions are logged as `wake` too; they are no wakes.
        let outcomes: Set = ["wander-return", "indoor-nofix", "potter-return", "leave-drift"]
        func isWake(_ e: LoggedEvent) -> Bool { e.kind == "wake" && !outcomes.contains(e.detail) }

        /// Seconds within [a, b) (clipped to now) that the last `kind` event's detail satisfied `want`,
        /// carrying the last known value in from before a.
        func seconds(_ kind: String, _ a: Date, _ b: Date, where want: (String) -> Bool) -> Double {
            let end = min(b, input.now)
            guard end > a else { return 0 }
            let ev = events.filter { $0.kind == kind }
            var cur = ev.last { $0.t <= a }?.detail
            var t = a, total = 0.0
            for e in ev where e.t > a && e.t < end {
                if let c = cur, want(c) { total += e.t.timeIntervalSince(t) }
                t = e.t; cur = e.detail
            }
            if let c = cur, want(c) { total += end.timeIntervalSince(t) }
            return total
        }

        var out = ["LifePath health report", "Generated: \(full.string(from: input.now))",
                   "Version: \(input.settings["version"] ?? "unknown")", "", "== Settings and permissions =="]
        out += input.settings.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }

        for d in 0..<max(days, 1) {
            let start = cal.date(byAdding: .day, value: d, to: first)!
            let next = cal.date(byAdding: .day, value: 1, to: start)!
            let dayEvents = events.filter { $0.t >= start && $0.t < next }
            let dayPoints = points.filter { $0.t >= start && $0.t < next }
            func counts(_ es: [LoggedEvent]) -> [String] {
                Dictionary(grouping: es, by: \.detail).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }
            }
            let wakes = counts(dayEvents.filter(isWake))
            let ends = counts(dayEvents.filter { $0.kind == "wake" && outcomes.contains($0.detail) })
            let gps = seconds("gps", start, next) { $0.hasPrefix("on") } / 3600
            out += ["", "== \(day.string(from: start)) ==",
                    "GPS on: \(String(format: "%.1f", gps)) h",
                    "Wakes by reason: \(wakes.isEmpty ? "none" : wakes.joined(separator: ", "))",
                    "Wake outcomes: \(ends.isEmpty ? "none" : ends.joined(separator: ", "))",
                    "Points: \(dayPoints.filter { $0.kind == .moving }.count) moving, \(dayPoints.filter { $0.kind == .still }.count) still, \(dayPoints.filter { $0.kind == .rough }.count) rough",
                    "hour  resting  wakes  spot checks  points  median hAcc  rough  struggle  drops  thermal  charging"]
            for h in 0..<24 {
                let a = cal.date(byAdding: .hour, value: h, to: start)!, b = cal.date(byAdding: .hour, value: 1, to: a)!
                let elapsed = min(b, input.now).timeIntervalSince(a)
                let pct = elapsed > 0 ? Int((seconds("state", a, b) { $0 == "still" } / elapsed * 100).rounded()) : 0
                let inHour = dayEvents.filter { $0.t >= a && $0.t < b }
                var worst = events.last { $0.kind == "thermal" && $0.t < a }.flatMap { thermalRank[$0.detail] }
                for e in inHour where e.kind == "thermal" { if let r = thermalRank[e.detail] { worst = max(worst ?? 0, r) } }
                let name = worst.map { w in thermalRank.first { $0.value == w }!.key } ?? "-"
                let chg = elapsed > 0 && events.contains { $0.kind == "charging" && $0.t < b }
                    ? "chg \(Int((seconds("charging", a, b) { $0 == "on" } / elapsed * 100).rounded()))%" : "chg -"
                let hourPoints = dayPoints.filter { $0.t >= a && $0.t < b }
                let accs = hourPoints.filter { $0.kind == .moving }.map(\.hAcc).sorted()
                let median = accs.isEmpty ? "-" : String(format: "%.1f", accs.count % 2 == 1
                    ? accs[accs.count / 2] : (accs[accs.count / 2 - 1] + accs[accs.count / 2]) / 2)
                var drops: [String: Int] = [:]
                for e in inHour where e.kind == "drops" {
                    for part in e.detail.split(separator: ",") {
                        let kv = part.split(separator: "=")
                        if kv.count == 2, let c = Int(kv[1]) { drops[String(kv[0]), default: 0] += c }
                    }
                }
                let dropText = ["accuracy", "rough-spacing", "stale", "future", "order", "teleport"]
                    .compactMap { r in drops[r].flatMap { $0 > 0 ? "\(r)=\($0)" : nil } }.joined(separator: ",")
                let spots = inHour.filter { $0.kind == "gps" && $0.detail == "on spotcheck" }.count
                out.append("\(hm.string(from: a))  \(pct)%  \(inHour.filter(isWake).count)  \(spots)  "
                           + "\(hourPoints.count)  acc \(median)  rough \(hourPoints.filter { $0.kind == .rough }.count)  "
                           + "struggle \(Int((seconds("struggle", a, b) { $0 == "on" } / 60).rounded()))  drops \(dropText.isEmpty ? "-" : dropText)  \(name)  \(chg)")
            }
        }

        let windowPoints = points.filter { $0.t >= first }
        let moving = windowPoints.filter { $0.kind == .moving }
        func n(_ f: (Double) -> Bool) -> Int { moving.filter { f($0.hAcc) }.count }
        out += ["", "== Accuracy of moving points ==", "<5 m: \(n { $0 < 5 })", "5–10 m: \(n { $0 >= 5 && $0 < 10 })",
                "10–20 m: \(n { $0 >= 10 && $0 < 20 })", "20–50 m: \(n { $0 >= 20 && $0 < 50 })", "≥50 m: \(n { $0 >= 50 })",
                "", "== iOS speed and direction accuracy (median per batch) =="]
        // shortcut: the median of batch medians, not of every fix; enough to judge whether iOS's values are trustworthy.
        let doppler = events.filter { $0.kind == "doppler" && $0.t >= first }
        func values(_ key: String) -> [Double] {
            doppler.compactMap { e in e.detail.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) } }.sorted()
        }
        let sa = values("speedAcc"), ca = values("courseAcc")
        out.append(doppler.isEmpty ? "none" : "speed \(sa.isEmpty ? "-" : String(format: "%.2f m/s", sa[sa.count / 2])), "
                   + "direction \(ca.isEmpty ? "-" : String(format: "%.1f°", ca[ca.count / 2])), batches \(doppler.count)")
        out += ["", "== Gaps over 15 min =="]
        var gaps = 0
        for (p, q) in zip(windowPoints, windowPoints.dropFirst()) where q.t.timeIntervalSince(p.t) > 15 * 60 {
            let last = events.last { $0.t <= p.t }.map { "\(hm.string(from: $0.t)) \($0.kind) \($0.detail)" } ?? "none"
            out.append("\(hm.string(from: p.t)) → \(hm.string(from: q.t)) (\(Int(q.t.timeIntervalSince(p.t) / 60)) min), last event: \(last)")
            gaps += 1
        }
        if gaps == 0 { out.append("none") }

        out += ["", "== Thermal and low-power events =="]
        let special = events.filter { ($0.kind == "thermal" || $0.kind == "lowPower") && $0.t >= first }
        out += special.isEmpty ? ["none"] : special.map { "\(full.string(from: $0.t)) \($0.kind) \($0.detail)" }

        out += ["", "== Last 200 events =="]
        let iso = ISO8601DateFormatter()
        out += events.suffix(200).map { "\(iso.string(from: $0.t)) \($0.kind) \($0.detail)" }
        return out.joined(separator: "\n")
    }
}
