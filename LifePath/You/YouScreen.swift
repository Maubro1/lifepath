import Core
import Diary
import SwiftUI

/// Everything about you in one page: status, lifetime numbers, your places, the year, and your days.
struct YouScreen: View {
    @State private var data: YouData?
    @State private var period = Period.year
    @State private var onScreen = false
    @AppStorage("countCycling") private var countCycling = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    enum Period: String, CaseIterable { case month = "This month", year = "This year", all = "All time" }

    private var visible: Bool { onScreen && scenePhase == .active }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    if let d = data {
                        facts(d)
                        places(d)
                        year(d)
                        days(d)
                    }
                }
                .padding(16)
            }
            .background(Color.page)
            .navigationTitle("You")
            .toolbar {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            .refreshable {
                if let diary = Recorder.shared.readDiary { await DayService.run(diary) }
                await load()
            }
            .navigationDestination(for: Date.self) { DayPage(day: $0) }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in if v { Task { await load() } } }
        .onChange(of: period) { Task { await load() } }
        .onChange(of: countCycling) { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: DayService.changed)) { _ in if visible { Task { await load() } } }
    }

    // MARK: sections

    private var status: some View {
        let r = Recorder.shared
        let s = TrackingStatus.evaluate(authorization: r.authorization, preciseLocation: r.preciseLocation, state: r.state,
                                        stillSince: r.stillSince, lastCheckIn: r.lastCheckIn, notSavingSince: r.notSavingSince,
                                        signingExpiry: SigningReminder.expiry, now: Date())
        let colour: Color = s.level == .problem ? Color(UIColor(Palette.cherry)) : s.level == .resting ? Color.muted : Color(UIColor(Palette.mode(.bike)))
        return HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(s.headline).font(.subheadline).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(Color.card, in: .rect(cornerRadius: 3))
        .accessibilityElement(children: .combine)
    }

    private func facts(_ d: YouData) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            fact(d.streets.formatted(), countCycling ? "streets walked or cycled" : "streets walked")
            fact(Format.distance(d.life.walked), "walked, all time")
            fact(d.neighbourhoods.formatted(), "neighbourhoods explored")
            fact(d.life.days.formatted(), "days recorded")
        }
        .padding(16)
        .background(Color.card, in: .rect(cornerRadius: 3))
    }

    private func fact(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(30, relativeTo: .title)).foregroundStyle(Color.ink)
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
            Text(caption).font(.caption).foregroundStyle(Color.muted)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func places(_ d: YouData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Your places")
            if d.newThisWeek > 0 {
                Text("+\(d.newThisWeek) new \(d.newThisWeek == 1 ? "street" : "streets") this week")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.satsuma)
            }
            if d.cities.isEmpty {
                Text("Progress per city appears once street maps and borders are downloaded.").font(.subheadline).foregroundStyle(Color.muted)
            }
            ForEach(d.cities, id: \.name) { c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(c.name).foregroundStyle(Color.ink)
                        Spacer()
                        Text(c.share.formatted(.percent.precision(.fractionLength(0)))).font(.display(17, relativeTo: .headline))
                            .foregroundStyle(Color.satsuma)
                    }
                    bar(c.share)
                }
                .padding(12)
                .background(Color.card, in: .rect(cornerRadius: 3))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func bar(_ share: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.inset)
                Rectangle().fill(Color.satsuma).frame(width: g.size.width * share)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func year(_ d: YouData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header("Your year")
                Spacer()
                Menu {
                    Picker("Period", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: {
                    HStack(spacing: 4) { Text(period.rawValue); Image(systemName: "chevron.down").font(.caption2) }
                        .font(.subheadline).padding(.horizontal, 10).frame(minHeight: 44)
                }
                .foregroundStyle(Color.ink)
            }
            // 52 weeks, oldest left: empty paper for still weeks, deeper satsuma for more walking.
            let most = max(d.weeks.max() ?? 0, 1)
            HStack(spacing: 2) {
                ForEach(Array(d.weeks.enumerated()), id: \.offset) { _, w in
                    Rectangle().fill(w > 0 ? Color.satsuma.opacity(0.25 + 0.75 * w / most) : Color.inset).frame(height: 18)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Walked in \(d.weeks.filter { $0 > 0 }.count) of the last 52 weeks")
            modeBar(d.byMode)
        }
        .padding(16)
        .background(Color.card, in: .rect(cornerRadius: 3))
    }

    @ViewBuilder private func modeBar(_ by: [TravelMode: Double]) -> some View {
        let total = by.values.reduce(0, +)
        if total > 0 {
            let parts = TravelMode.allCases.compactMap { m in by[m].map { (mode: m, share: $0 / total) } }.filter { $0.share > 0.005 }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.mode) { p in
                        Rectangle().fill(Color(UIColor(Palette.mode(p.mode)))).frame(width: max(2, (g.size.width - CGFloat(parts.count * 2)) * p.share))
                    }
                }
            }
            .frame(height: 18)
            .accessibilityHidden(true)
            FlowLegend(parts: parts)
        } else {
            Text("No classified trips in this period yet.").font(.subheadline).foregroundStyle(Color.muted)
        }
    }

    private func days(_ d: YouData) -> some View {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
            header("Your days")
            ForEach(d.months, id: \.title) { month in
                Text(month.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.muted).padding(.top, 8)
                ForEach(month.days, id: \.key) { day in
                    if let date = Format.date(day.key) {
                        NavigationLink(value: date) { DayRow(day: day, date: date, dark: scheme == .dark) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.display(22, relativeTo: .title2)).foregroundStyle(Color.ink)
    }

    // MARK: loading

    private func load() async {
        guard let diary = Recorder.shared.readDiary else { return }
        let bike = countCycling, now = Date(), cal = Calendar.current
        let from: Date = switch period {
        case .month: cal.date(byAdding: .month, value: -1, to: now)!
        case .year: cal.date(byAdding: .year, value: -1, to: now)!
        case .all: .distantPast
        }
        data = await Task.detached(priority: .userInitiated) { () -> YouData? in
            try? YouData.read(diary, bike: bike, from: from, now: now, calendar: cal)
        }.value ?? data
    }
}

/// Mode legend under the bar: a square and a share per mode.
private struct FlowLegend: View {
    let parts: [(mode: TravelMode, share: Double)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(parts, id: \.mode) { p in
                HStack(spacing: 6) {
                    Rectangle().fill(Color(UIColor(Palette.mode(p.mode)))).frame(width: 10, height: 10)
                    Text("\(p.mode.label) \(p.share.formatted(.percent.precision(.fractionLength(0))))").font(.caption).foregroundStyle(Color.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One day in the list: its map picture, title and numbers.
private struct DayRow: View {
    let day: YouData.Day
    let date: Date
    let dark: Bool
    @State private var picture: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Color.inset)
                if let picture { Image(uiImage: picture).resizable().scaledToFill() }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 3))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dayTitle(date)).font(.headline).foregroundStyle(Color.ink)
                Text(day.moving > 0 ? "\(Format.distance(day.distance)) · \(Format.duration(day.moving))" + (day.steps.map { " · \($0.formatted()) steps" } ?? "")
                     : "No trips" + (day.steps.map { " · \($0.formatted()) steps" } ?? ""))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
                if day.new > 0 {
                    Text("+\(day.new) new \(day.new == 1 ? "street" : "streets")").font(.subheadline.weight(.semibold)).foregroundStyle(Color.satsuma)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.card, in: .rect(cornerRadius: 3))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this day")
        .task(id: dark) {
            guard let diary = Recorder.shared.readDiary, day.moving > 0 else { return }
            let from = date, to = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            let lines = await Task.detached(priority: .utility) { (try? diary.tripLines(from: from, to: to)) ?? [] }.value
            picture = await DaySnapshot.image(key: day.key, lines: lines.map { $0.coords.map { (lat: $0.lat, lon: $0.lon) } }, dark: dark,
                                              size: CGSize(width: 64, height: 64))
        }
    }
}

/// What the You tab shows, read off the main actor in one go.
struct YouData: Sendable {
    struct Day: Sendable { var key: String; var distance: Double; var moving: TimeInterval; var steps: Int?; var new: Int }
    var life: LifeStats
    var streets: Int
    var neighbourhoods: Int
    var newThisWeek: Int
    var cities: [(name: String, share: Double)]
    var weeks: [Double]                 // metres walked per week, 52, oldest first
    var byMode: [TravelMode: Double]
    var months: [(title: String, days: [Day])]

    static func read(_ diary: Diary, bike: Bool, from: Date, now: Date, calendar cal: Calendar) throws -> YouData {
        let progress = try diary.areaProgress(bike: bike), names = try diary.areaNames()
        let cities = progress.filter { names[$0.areaId]?.level == 8 && $0.total > 0 }
            .map { (name: names[$0.areaId]!.name, share: Double($0.covered) / Double($0.total), covered: $0.covered) }
            .sorted { $0.covered > $1.covered }.map { (name: $0.name, share: $0.share) }
        let explored = progress.filter { (names[$0.areaId]?.level ?? 0) > 8 && $0.covered > 0 }.count
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let days = try diary.days()
        var weeks = [Double](repeating: 0, count: 52)
        for d in days {
            guard let date = Format.date(d.summary.day) else { continue }
            let back = cal.dateComponents([.weekOfYear], from: cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date, to: weekStart).weekOfYear ?? 99
            if (0..<52).contains(back) { weeks[51 - back] += d.summary.walked }
        }
        let lines = try diary.tripLines(from: from, to: now), modes = try diary.modes(from: from, to: now).values.flatMap { $0 }
        var months: [(title: String, days: [Day])] = []
        for d in days {
            guard let date = Format.date(d.summary.day) else { continue }
            let title = date.formatted(.dateTime.month(.wide).year())
            let end = cal.date(byAdding: .day, value: 1, to: date)!
            let day = Day(key: d.summary.day, distance: d.summary.distance, moving: d.summary.movingTime, steps: d.steps,
                          new: try diary.newStreets(from: date, to: end, bike: bike))
            if months.last?.title == title { months[months.count - 1].days.append(day) } else { months.append((title, [day])) }
        }
        return YouData(life: try diary.lifeStats(), streets: try diary.streetsWalked(bike: bike)?.covered ?? 0, neighbourhoods: explored,
                       newThisWeek: try diary.newStreets(from: weekStart, to: .distantFuture, bike: bike), cities: cities, weeks: weeks,
                       byMode: DayStory.distanceByMode(lines: lines, modes: modes), months: months)
    }
}
