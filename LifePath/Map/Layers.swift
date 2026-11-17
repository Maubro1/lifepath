import Core
import MapKit
import UIKit

/// One overlay covering the world for the whole life of the map; its renderer draws whatever content it currently holds.
/// Content is swapped, never the overlay, and only the rects that changed are redrawn: MapKit keeps the old tiles meanwhile, so nothing blinks.
final class LayerOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// What a layer draws: immutable, so a tile drawn on a background thread never sees half an update.
protocol LayerContent: Sendable {
    var style: String { get }                 // a change here redraws everything
    var items: [String: MKMapRect] { get }    // key → area it covers; only changed keys redraw
    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer)
}

final class LayerRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var content: LayerContent?

    func set(_ new: LayerContent?) {
        lock.lock(); let old = content; content = new; lock.unlock()
        guard let new, let old, new.style == old.style else { setNeedsDisplay(); return }
        let was = old.items, now = new.items   // computed: read once, not once per key
        var dirty = MKMapRect.null
        for (k, r) in now where was[k] == nil { dirty = dirty.union(r) }
        for (k, r) in was where now[k] == nil { dirty = dirty.union(r) }
        if !dirty.isNull { setNeedsDisplay(dirty.insetBy(dx: -dirty.width * 0.02 - 2000, dy: -dirty.height * 0.02 - 2000)) }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        lock.lock(); let c = content; lock.unlock()
        c?.draw(mapRect, scale: zoomScale, in: context, renderer: self)
    }
}

// MARK: - helpers

func cgColor(_ h: Hex, dark: Bool, alpha: CGFloat = 1) -> CGColor {
    UIColor(rgb: dark ? h.dark : h.light).withAlphaComponent(alpha).cgColor
}

/// The map rect around coordinates, grown by `pad` map points.
func mapRect(_ coords: [(lat: Double, lon: Double)], pad: Double) -> MKMapRect {
    var r = MKMapRect.null
    for c in coords { let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)); r = r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
    return r.insetBy(dx: -pad, dy: -pad)
}

extension MKOverlayRenderer {
    func path(_ coords: [(lat: Double, lon: Double)], closed: Bool = false) -> CGPath {
        let p = CGMutablePath()
        for (i, c) in coords.enumerated() {
            let q = point(for: MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        if closed { p.closeSubpath() }
        return p
    }
}

/// Map points per metre at a latitude (Web Mercator).
func pointsPerMetre(_ lat: Double) -> Double { MKMapPointsPerMeterAtLatitude(lat) }

// MARK: - fog

/// The paper over the map, cleared along trips and at places.
struct FogContent: LayerContent {
    var strokes: [(key: String, rect: MKMapRect, stroke: FogStroke)]
    var dark: Bool
    static let feather = 4.0   // m

    var style: String { "fog\(dark)" }
    var items: [String: MKMapRect] { Dictionary(strokes.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a }) }

    init(_ strokes: [(key: String, stroke: FogStroke)], dark: Bool) {
        self.dark = dark
        self.strokes = strokes.map { s in
            let lat = s.stroke.coords.first?.lat ?? 0
            return (s.key, mapRect(s.stroke.coords, pad: (s.stroke.halfWidth + Self.feather) * pointsPerMetre(lat) + 400), s.stroke)
        }
    }

    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer) {
        ctx.setFillColor(cgColor(Palette.page, dark: dark))
        ctx.fill(renderer.rect(for: rect))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let near = rect.insetBy(dx: -8 / scale, dy: -8 / scale)   // strokes wider than an item's padding when zoomed out
        let minimum = 2 / scale   // a cleared band never drawn under 2 pt on screen
        // Soft edge first (half cleared, wider), then the band itself fully cleared.
        for (blend, extra, alpha) in [(CGBlendMode.destinationOut, Self.feather, 0.5), (.clear, 0, 1)] {
            ctx.setBlendMode(blend)
            ctx.setStrokeColor(UIColor(white: 0, alpha: alpha).cgColor); ctx.setFillColor(UIColor(white: 0, alpha: alpha).cgColor)
            for s in strokes where s.rect.intersects(near) {
                let lat = s.stroke.coords[0].lat
                let w = max(2 * (s.stroke.halfWidth + extra) * pointsPerMetre(lat), minimum)
                if s.stroke.coords.count == 1 {
                    let c = renderer.point(for: MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: s.stroke.coords[0].lon)))
                    ctx.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w))
                } else {
                    ctx.setLineWidth(w); ctx.addPath(renderer.path(s.stroke.coords)); ctx.strokePath()
                }
            }
        }
        ctx.setBlendMode(.normal)
    }
}

// MARK: - streets

/// Walked streets glowing over faint unwalked ones; zoomed out, neighbourhoods shaded by progress instead.
struct StreetsContent: LayerContent {
    var walked: [(key: String, rect: MKMapRect, coords: [(lat: Double, lon: Double)])]
    var unwalked: [(key: String, rect: MKMapRect, coords: [(lat: Double, lon: Double)])]
    var shading: [(key: String, rect: MKMapRect, rings: [[(lat: Double, lon: Double)]], holes: [[(lat: Double, lon: Double)]], share: Double)]
    var dark: Bool

    var style: String { "streets\(dark)" }
    var items: [String: MKMapRect] {
        var d: [String: MKMapRect] = [:]
        for w in walked { d["w" + w.key] = w.rect }
        for u in unwalked { d["u" + u.key] = u.rect }
        for s in shading { d["s" + s.key] = s.rect }
        return d
    }

    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer) {
        let lat = rect.origin.coordinate.latitude
        let near = rect.insetBy(dx: -8 / scale, dy: -8 / scale)
        // On-screen length of a 20 m street segment: below 0.5 pt shading only, above 1 pt streets only, cross-faded between.
        let seg = 20 * pointsPerMetre(lat) * Double(scale)
        let streets = min(1, max(0, (seg - 0.5) / 0.5))
        if streets < 1 {
            for s in shading where s.rect.intersects(near) {
                ctx.setFillColor(cgColor(Palette.satsuma, dark: dark, alpha: CGFloat((0.15 + 0.6 * s.share) * (1 - streets))))
                for r in s.rings { ctx.addPath(renderer.path(r, closed: true)) }
                for h in s.holes { ctx.addPath(renderer.path(h, closed: true)) }
                ctx.fillPath(using: .evenOdd)
            }
        }
        guard streets > 0 else { return }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(cgColor(Palette.muted, dark: dark, alpha: 0.35 * streets)); ctx.setLineWidth(1 / scale)
        for u in unwalked where u.rect.intersects(near) { ctx.addPath(renderer.path(u.coords)) }
        ctx.strokePath()
        for (width, alpha) in [(6.0, 0.25), (2.5, 1.0)] {   // glow, then the line
            ctx.setStrokeColor(cgColor(Palette.satsuma, dark: dark, alpha: alpha * streets)); ctx.setLineWidth(width / scale)
            for w in walked where w.rect.intersects(near) { ctx.addPath(renderer.path(w.coords)) }
            ctx.strokePath()
        }
    }
}

// MARK: - lines

/// Your own lines for the chosen period: one colour, or by travel mode, date or speed; never faded with age.
struct LinesContent: LayerContent {
    var lines: [(rect: MKMapRect, line: MapLine)]
    var colour: LineColour
    var hidden: Set<TravelMode>   // with colour by mode: modes switched off in the legend
    var edged: Bool   // Streets mode: a dark edge keeps lines apart from the glowing streets
    var dark: Bool

    var style: String { "lines\(colour)\(edged)\(dark)\(hidden.map(\.rawValue).sorted())" }
    var items: [String: MKMapRect] { Dictionary(lines.map { ($0.line.key, $0.rect) }, uniquingKeysWith: { a, _ in a }) }

    init(_ lines: [MapLine], colour: LineColour, hidden: Set<TravelMode>, edged: Bool, dark: Bool) {
        self.colour = colour; self.hidden = hidden; self.edged = edged; self.dark = dark
        self.lines = lines.map { (mapRect($0.coords, pad: 400), $0) }
    }

    private func hex(_ l: MapLine, _ i: Int) -> Hex {
        switch colour {
        case .plain: return Palette.satsuma
        case .date: let r = Palette.dateRamp(1 - l.dateFraction); return Hex(light: r.light, dark: r.dark)
        case .mode: return l.modes[i].map(Palette.mode) ?? Palette.unsure
        case .speed:
            switch SpeedBand(speed: l.speeds[i]) { case .walk: return Palette.mode(.walk); case .bike: return Palette.mode(.bike); case .drive: return Palette.mode(.car) }
        }
    }

    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer) {
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let near = rect.insetBy(dx: -8 / scale, dy: -8 / scale)
        for (r, l) in lines where r.intersects(near) && l.coords.count > 1 {
            let width = (l.rough ? 2.0 : 3.0) / scale
            ctx.setLineDash(phase: 0, lengths: l.rough ? [4 / scale, 4 / scale] : [])
            if edged && hidden.isEmpty {
                ctx.setStrokeColor(cgColor(Palette.text, dark: dark)); ctx.setLineWidth(width + 2 / scale)
                ctx.addPath(renderer.path(l.coords)); ctx.strokePath()
            }
            ctx.setLineWidth(width)
            // Runs of one colour as one path.
            var a = 0
            for b in 1..<l.coords.count where b == l.coords.count - 1 || hex(l, b) != hex(l, a) {
                if colour != .mode || !(l.modes[a].map(hidden.contains) ?? false) {
                    ctx.setStrokeColor(cgColor(hex(l, a), dark: dark))
                    ctx.addPath(renderer.path(Array(l.coords[a...b]))); ctx.strokePath()
                }
                a = b
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
