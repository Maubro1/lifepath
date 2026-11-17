import Foundation

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

    /// "Today", "Yesterday", else "Mon 16 Nov".
    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
