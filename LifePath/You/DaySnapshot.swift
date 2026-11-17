import Core
import MapKit
import UIKit

/// Which tab is showing, and a day the Map tab should show on its own.
@MainActor @Observable final class AppNav {
    static let shared = AppNav()
    var tab = 0          // 0 Map, 1 You
    var showDay: Date?   // set by a day page; the map takes it and clears it
}

/// A small picture of a day: the muted map with that day's lines in satsuma. Made once, kept in Caches.
@MainActor enum DaySnapshot {
    static func image(key: String, lines: [[(lat: Double, lon: Double)]], dark: Bool, size: CGSize) async -> UIImage? {
        let all = lines.joined()
        guard let first = all.first else { return nil }
        let name = "\(key)-\(dark ? "d" : "l")-\(Int(size.width))x\(Int(size.height))-\(all.count).png"
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("daymaps")
        let file = dir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data, scale: UIScreen.main.scale) { return img }

        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in all { minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat); minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon) }
        let o = MKMapSnapshotter.Options()
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.3), longitudeDelta: max(0.006, (maxLon - minLon) * 1.3))
        o.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2), span: span)
        o.size = size
        o.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        o.preferredConfiguration = config
        guard let shot = try? await MKMapSnapshotter(options: o).start() else { return nil }
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            shot.image.draw(at: .zero)
            let c = ctx.cgContext
            c.setStrokeColor(UIColor(rgb: dark ? Palette.satsuma.dark : Palette.satsuma.light).cgColor)
            c.setLineWidth(2); c.setLineCap(.round); c.setLineJoin(.round)
            for line in lines where line.count > 1 {
                for (i, p) in line.enumerated() {
                    let q = shot.point(for: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    if i == 0 { c.move(to: q) } else { c.addLine(to: q) }
                }
                c.strokePath()
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? img.pngData()?.write(to: file)
        return img
    }
}
