import Core
import MapKit

/// Heat cells as Mercator squares with a precomputed alpha.
final class HeatOverlay: NSObject, MKOverlay {
    let cells: [(rect: MKMapRect, alpha: Double)]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(_ grid: [HeatCell: TimeInterval]) {
        let maxS = grid.values.max() ?? 0
        let side = Heat.cellSize * MKMapSize.world.width / (2 * .pi * 6_378_137)   // Mercator metres → map points
        cells = grid.map { cell, s in
            let c = Heat.center(of: cell)
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
            return (MKMapRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side), MapColors.heatAlpha(s, max: maxS))
        }
        boundingMapRect = cells.reduce(MKMapRect.null) { $0.union($1.rect) }
        coordinate = boundingMapRect.isNull ? kCLLocationCoordinate2DInvalid : MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
}

final class HeatRenderer: MKOverlayRenderer {
    nonisolated(unsafe) private let cells: [(rect: MKMapRect, alpha: Double)]   // immutable after init; draw runs off the main thread

    init(_ heat: HeatOverlay) {
        cells = heat.cells
        super.init(overlay: heat)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let orange = (r: 0xF2 / 255.0, g: 0x8C / 255.0, b: 0x28 / 255.0)
        for cell in cells where cell.rect.intersects(mapRect) {
            context.setFillColor(red: orange.r, green: orange.g, blue: orange.b, alpha: cell.alpha)
            context.fill(rect(for: cell.rect))
        }
    }
}
