import Core
import MapKit
import SwiftUI

/// A trip line that carries its own colouring data to the renderer.
final class TrackLine: MKPolyline {
    var line: MapLine!
}

struct TrackMapView: UIViewRepresentable {
    let data: MapData?
    let bySpeed: Bool
    let satellite: Bool
    let visible: Bool
    let onRegion: @MainActor (MKCoordinateRegion, Double) -> Void   // region, view width in points

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
            map.preferredConfiguration = satellite ? MKImageryMapConfiguration() : MKStandardMapConfiguration()
        }
        guard let data, data.generation != c.shownGeneration || bySpeed != c.shownBySpeed else { return }
        c.shownGeneration = data.generation
        c.shownBySpeed = bySpeed
        map.removeOverlays(map.overlays)
        if !data.heat.isEmpty { map.addOverlay(HeatOverlay(data.heat)) }   // first, so lines draw on top
        map.addOverlays(data.lines.map { l in
            let coords = l.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let poly = TrackLine(coordinates: coords, count: coords.count)
            poly.line = l
            return poly
        })
        map.addOverlays(data.still.map { MKCircle(center: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), radius: 3) })
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackMapView
        var shownGeneration = -1
        var shownBySpeed = false
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

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
                r.lineWidth = 3
                return r
            }
            let r = MKPolylineRenderer(polyline: track)
            let c = MapColors.byDate(l.dateFraction)
            r.strokeColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            r.lineWidth = 3
            return r
        }
    }
}
