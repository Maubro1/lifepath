import Core
import MapKit
import SwiftUI

/// A trip line that carries its own colouring data to the renderer.
final class TrackLine: MKPolyline {
    var line: MapLine!
}

/// A learned place's pin; the marker size follows the time spent there.
final class PlaceAnnotation: MKPointAnnotation {
    var placeId: Int64 = 0
    var totalSeconds = 0.0
}

struct TrackMapView: UIViewRepresentable {
    let data: MapData?
    let bySpeed: Bool
    let satellite: Bool
    let visible: Bool
    let onRegion: @MainActor (MKCoordinateRegion, Double) -> Void   // region, view width in points
    let onPlace: @MainActor (Int64) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        let locate = MKUserTrackingButton(mapView: map)
        locate.accessibilityLabel = "Locate me"
        locate.backgroundColor = .systemBackground
        locate.layer.cornerRadius = 8
        locate.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(locate)
        NSLayoutConstraint.activate([
            locate.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 8),
            locate.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if map.showsUserLocation != visible { map.showsUserLocation = visible }   // location only while on screen
        if (map.preferredConfiguration is MKImageryMapConfiguration) != satellite {
            let standard = MKStandardMapConfiguration()
            standard.pointOfInterestFilter = .excludingAll   // as makeUIView
            map.preferredConfiguration = satellite ? MKImageryMapConfiguration() : standard
        }
        guard let data, data.generation != c.shownGeneration || bySpeed != c.shownBySpeed else { return }
        c.shownGeneration = data.generation
        c.shownBySpeed = bySpeed
        // Overlays are keyed: unchanged ones stay on the map, new ones are added before stale ones go, so nothing blinks.
        var wanted: [(key: String, level: MKOverlayLevel, make: () -> MKOverlay)] = []
        if !data.heat.isEmpty {   // under the labels, so lines always draw on top
            let heat = data.heat
            wanted.append(("h\(heat.hashValue)", .aboveRoads, { HeatOverlay(heat) }))
        }
        for (id, cells) in data.outlines {
            wanted.append(("o\(id)-\(cells.hashValue)", .aboveRoads, {
                MKMultiPolygon(cells.map { c in   // one square per 5 m cell; one shape, so the fill has no seams
                    let a = PlaceGrid.center(of: c), b = PlaceGrid.center(of: PlaceCell(x: c.x + 1, y: c.y + 1))
                    let h = ((b.lat - a.lat) / 2, (b.lon - a.lon) / 2)
                    var corners = [(-1.0, -1.0), (-1, 1), (1, 1), (1, -1)].map {
                        CLLocationCoordinate2D(latitude: a.lat + $0.0 * h.0, longitude: a.lon + $0.1 * h.1)
                    }
                    return MKPolygon(coordinates: &corners, count: 4)
                })
            }))
        }
        for l in data.lines {
            wanted.append(("l\(bySpeed)-\(l.key)", .aboveLabels, {   // the renderer depends on the colouring
                let coords = l.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let poly = TrackLine(coordinates: coords, count: coords.count)
                poly.line = l
                return poly
            }))
        }
        for p in data.still {
            wanted.append(("s\(p.lat),\(p.lon)", .aboveLabels, { MKCircle(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: 3) }))
        }
        for w in wanted where c.shown[w.key] == nil {
            let o = w.make()
            c.shown[w.key] = o
            map.addOverlay(o, level: w.level)
        }
        let keys = Set(wanted.map(\.key))
        let stale = c.shown.filter { !keys.contains($0.key) }
        map.removeOverlays(Array(stale.values))
        for k in stale.keys { c.shown[k] = nil }
        let pins = data.places.map { p -> PlaceAnnotation in
            let a = PlaceAnnotation()
            let pin = p.pin!   // the loader keeps only places with a pin
            a.coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
            a.title = p.name ?? String(format: "Place near %.4f, %.4f", pin.lat, pin.lon)
            a.placeId = p.id
            a.totalSeconds = p.totalSeconds
            return a
        }
        map.removeAnnotations(map.annotations.filter { $0 is PlaceAnnotation })
        map.addAnnotations(pins)
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackMapView
        var shownGeneration = -1
        var shownBySpeed = false
        var shown: [String: MKOverlay] = [:]   // overlays on the map by key
        private var centered = false

        init(_ parent: TrackMapView) { self.parent = parent }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegion(map.region, Double(map.bounds.width))
        }

        /// The first fix centres the map once; after that the owner pans freely.
        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !centered, let loc = userLocation.location else { return }
            centered = true
            map.setRegion(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? PlaceAnnotation else { return nil }   // nil keeps the system's own location dot
            let v = map.dequeueReusableAnnotationView(withIdentifier: "place") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: "place")
            v.annotation = a
            v.markerTintColor = .systemIndigo
            v.glyphImage = UIImage(systemName: "mappin")
            v.displayPriority = .required   // every pin at every zoom
            let scale = a.totalSeconds < 10 * 3600 ? 0.7 : a.totalSeconds < 100 * 3600 ? 0.85 : 1.0
            v.transform = CGAffineTransform(scaleX: scale, y: scale)
            v.accessibilityLabel = a.title
            v.accessibilityHint = "Shows this place's details"
            return v
        }

        func mapView(_ map: MKMapView, didSelect annotation: MKAnnotation) {
            guard let a = annotation as? PlaceAnnotation else { return }
            map.deselectAnnotation(a, animated: false)
            parent.onPlace(a.placeId)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let shape = overlay as? MKMultiPolygon {
                let r = MKMultiPolygonRenderer(multiPolygon: shape)
                r.fillColor = UIColor.systemIndigo.withAlphaComponent(0.15)
                return r
            }
            if let heat = overlay as? HeatOverlay { return HeatRenderer(heat) }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor = .systemGray
                return r
            }
            guard let track = overlay as? TrackLine else { return MKOverlayRenderer(overlay: overlay) }
            let l = track.line!
            if parent.bySpeed {
                let r = MKGradientPolylineRenderer(polyline: track)
                r.setColors(l.speeds.map { s -> UIColor in
                    switch SpeedBand(speed: s) { case .walk: .systemGreen; case .bike: .systemBlue; case .drive: .systemRed }
                }, locations: l.locations.map { CGFloat($0) })
                rough(r, l)
                return r
            }
            let r = MKPolylineRenderer(polyline: track)
            let c = MapColors.byDate(l.dateFraction)
            r.strokeColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            rough(r, l)
            return r
        }

        /// Rough stretches draw thinner and dashed, so their precision is never overstated.
        private func rough(_ r: MKPolylineRenderer, _ l: MapLine) {
            r.lineWidth = l.rough ? 2 : 3
            if l.rough { r.lineDashPattern = [4, 4] }
        }
    }
}
