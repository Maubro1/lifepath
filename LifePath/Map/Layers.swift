import Core
import MapKit
import UIKit
import Accelerate

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

extension MKOverlayRenderer {
    /// A smooth curve through every point (uniform Catmull–Rom as cubic Béziers), so kept vertices stay on the line.
    // shortcut: uniform, not centripetal, Catmull–Rom; upgrade if tight corners show overshoot
    func curve(_ coords: [(lat: Double, lon: Double)]) -> CGPath {
        let q = coords.map { point(for: MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))) }
        let p = CGMutablePath()
        guard let first = q.first else { return p }
        p.move(to: first)
        guard q.count > 2 else { if q.count == 2 { p.addLine(to: q[1]) }; return p }
        for i in 0..<(q.count - 1) {
            let p0 = q[max(i - 1, 0)], p1 = q[i], p2 = q[i + 1], p3 = q[min(i + 2, q.count - 1)]
            p.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return p
    }
}

/// Items by grid cell (1/4096 of the world's width, about 10 km at 52°), so a tile visits only the items near it.
struct GridIndex: Sendable {
    static let cell = MKMapRect.world.width / 4096
    private var cells: [Int: [Int]] = [:], big: [Int] = []

    init(_ rects: [MKMapRect]) {
        for (i, r) in rects.enumerated() {
            let x0 = Int(r.minX / Self.cell), x1 = Int(r.maxX / Self.cell), y0 = Int(r.minY / Self.cell), y1 = Int(r.maxY / Self.cell)
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 64 { big.append(i); continue }   // a huge item is checked by every tile
            for x in x0...x1 { for y in y0...y1 { cells[x * 8192 + y, default: []].append(i) } }
        }
    }

    func items(in r: MKMapRect) -> [Int] {
        var out = Set(big)
        for x in Int(r.minX / Self.cell)...Int(r.maxX / Self.cell) {
            for y in Int(r.minY / Self.cell)...Int(r.maxY / Self.cell) { out.formUnion(cells[x * 8192 + y] ?? []) }
        }
        return out.sorted()   // stable drawing order
    }
}

/// Map points of coordinates, converted once when content is built rather than on every tile draw.
func mapPoints(_ coords: [(lat: Double, lon: Double)]) -> [MKMapPoint] {
    coords.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
}

extension MKOverlayRenderer {
    func path(_ pts: [MKMapPoint]) -> CGPath {
        let p = CGMutablePath()
        for (i, m) in pts.enumerated() { if i == 0 { p.move(to: point(for: m)) } else { p.addLine(to: point(for: m)) } }
        return p
    }
}

/// Map points per metre at a latitude (Web Mercator).
func pointsPerMetre(_ lat: Double) -> Double { MKMapPointsPerMeterAtLatitude(lat) }

// MARK: - fog

/// The paper over the map, cleared along trips and at places.
struct FogContent: LayerContent {
    var strokes: [(key: String, rect: MKMapRect, stroke: FogStroke)]
    var points: [[MKMapPoint]]
    var grid: GridIndex
    var dark: Bool
    static let feather = 4.0   // m
    static let opacity = 0.82   // see-through paper; set here, never through the renderer's alpha (stalls tiles on iOS 18)

    var style: String { "fog\(dark)" }
    var items: [String: MKMapRect] { Dictionary(strokes.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a }) }

    init(_ strokes: [(key: String, stroke: FogStroke)], dark: Bool) {
        self.dark = dark
        self.strokes = strokes.map { s in
            let lat = s.stroke.coords.first?.lat ?? 0
            return (s.key, mapRect(s.stroke.coords, pad: (s.stroke.halfWidth + Self.feather) * pointsPerMetre(lat) + 400), s.stroke)
        }
        points = self.strokes.map { mapPoints($0.stroke.coords) }
        grid = GridIndex(self.strokes.map(\.rect))
    }

    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer) {
        ctx.setFillColor(cgColor(Palette.page, dark: dark, alpha: Self.opacity))
        ctx.fill(renderer.rect(for: rect))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let near = rect.insetBy(dx: -8 / scale, dy: -8 / scale)   // strokes wider than an item's padding when zoomed out
        let minimum = 2 / scale   // a cleared band never drawn under 2 pt on screen
        // Soft edge first (half cleared, wider), then the band itself fully cleared.
        for (blend, extra, alpha) in [(CGBlendMode.destinationOut, Self.feather, 0.5), (.clear, 0, 1)] {
            ctx.setBlendMode(blend)
            ctx.setStrokeColor(UIColor(white: 0, alpha: alpha).cgColor); ctx.setFillColor(UIColor(white: 0, alpha: alpha).cgColor)
            for i in grid.items(in: near) where strokes[i].rect.intersects(near) {
                let s = strokes[i]
                let w = max(2 * (s.stroke.halfWidth + extra) * pointsPerMetre(s.stroke.coords[0].lat), minimum)
                if points[i].count == 1 {
                    let c = renderer.point(for: points[i][0])
                    ctx.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w))
                } else {
                    ctx.setLineWidth(w); ctx.addPath(renderer.path(points[i])); ctx.strokePath()
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
                ctx.addPath(renderer.curve(l.coords)); ctx.strokePath()
            }
            ctx.setLineWidth(width)
            // Only vertices whose Visvalingam area beats this zoom's pixel² (nested sets: zooming never reshapes a line).
            let px = 1 / (Double(scale) * pointsPerMetre(l.coords[0].lat)), cut = px * px
            let shown = l.importance.count == l.coords.count ? l.coords.indices.filter { l.importance[$0] >= cut } : Array(l.coords.indices)
            // Runs of one colour as one curve.
            var a = 0
            for b in 1..<shown.count where b == shown.count - 1 || hex(l, shown[b]) != hex(l, shown[a]) {
                if colour != .mode || !(l.modes[shown[a]].map(hidden.contains) ?? false) {
                    ctx.setStrokeColor(cgColor(hex(l, shown[a]), dark: dark))
                    ctx.addPath(renderer.curve(shown[a...b].map { l.coords[$0] })); ctx.strokePath()
                }
                a = b
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }
}

// MARK: - heat

/// Where you go most: every trip line added into a soft density image per tile (a quarter of its pixels, blurred once),
/// coloured through the warm ramp. Places glow by time spent. Scaled by the busiest spot loaded at this zoom.
struct HeatContent: LayerContent {
    var lines: [(key: String, rect: MKMapRect, points: [MKMapPoint])]
    var places: [(point: MKMapPoint, hours: Double)]
    var grid: GridIndex
    var max: Double   // passes through the busiest cell at the loading zoom
    var dark: Bool
    static let pass: Float = 1 / 16   // grey added per trip; a count is value × 16

    var style: String { "heat\(dark)\(Int(max))" }
    var items: [String: MKMapRect] { Dictionary(lines.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a }) }

    init(_ lines: [(key: String, coords: [(lat: Double, lon: Double)])], places: [(lat: Double, lon: Double, hours: Double)], max: Double, dark: Bool) {
        self.lines = lines.map { ($0.key, mapRect($0.coords, pad: 800), mapPoints($0.coords)) }
        self.places = places.map { (MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)), $0.hours) }
        grid = GridIndex(self.lines.map(\.rect))
        self.max = max; self.dark = dark
    }

    func draw(_ rect: MKMapRect, scale: MKZoomScale, in ctx: CGContext, renderer: MKOverlayRenderer) {
        let px = Double(scale) / 4, m = 6   // buffer pixels per map point; margin pixels so blur and strokes cross tile seams
        let w = Int((rect.width * px).rounded(.up)) + 2 * m, h = Int((rect.height * px).rounded(.up)) + 2 * m
        guard w > 2 * m, h > 2 * m, max > 0,
              let density = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue)
        else { return }
        // Buffer coordinates: y grows downwards like map points.
        density.translateBy(x: 0, y: CGFloat(h)); density.scaleBy(x: 1, y: -1)
        func b(_ p: MKMapPoint) -> CGPoint { CGPoint(x: (p.x - rect.minX) * px + Double(m), y: (p.y - rect.minY) * px + Double(m)) }
        density.setBlendMode(.plusLighter); density.setLineCap(.round); density.setLineJoin(.round)
        density.setStrokeColor(gray: 1, alpha: CGFloat(Self.pass)); density.setLineWidth(1.5)
        let near = rect.insetBy(dx: -Double(m) / px, dy: -Double(m) / px)
        for i in grid.items(in: near) where lines[i].rect.intersects(near) && lines[i].points.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: lines[i].points.map(b))
            density.addPath(path); density.strokePath()   // one stroke per trip: a trip counts once where it overlaps itself
        }
        for p in places where near.contains(p.point) {
            let c = b(p.point), r = 3.0
            density.setFillColor(gray: 1, alpha: CGFloat(Swift.min(1, Double(Self.pass) * (1 + log1p(p.hours)))))
            density.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        guard let data = density.data else { return }
        // Blur once: two 3×3 tent passes soften the lines into gradients.
        var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        var tmp = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeMutableBytes { t in
            var dst = vImage_Buffer(data: t.baseAddress, height: src.height, width: src.width, rowBytes: w * 4)
            vImageTentConvolve_PlanarF(&src, &dst, nil, 0, 0, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            vImageTentConvolve_PlanarF(&dst, &src, nil, 0, 0, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
        }
        // Colour through the ramp into an RGBA image, margins cropped.
        let values = data.bindMemory(to: Float.self, capacity: w * h)
        let cw = w - 2 * m, ch = h - 2 * m
        var rgba = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            for x in 0..<cw {
                let count = Double(values[(y + m) * w + x + m] / Self.pass)
                guard count > 0.05 else { continue }
                let c = HeatRamp.colour(HeatRamp.level(count: count, max: max)), k = (y * cw + x) * 4
                rgba[k] = UInt8(c.r * c.a * 255); rgba[k + 1] = UInt8(c.g * c.a * 255); rgba[k + 2] = UInt8(c.b * c.a * 255); rgba[k + 3] = UInt8(c.a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        // The map's context runs y downwards; an image draws y upwards, so flip around the tile.
        let r = renderer.rect(for: rect)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.minY + r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        ctx.restoreGState()
    }
}
