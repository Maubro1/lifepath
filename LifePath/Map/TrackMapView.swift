import Core
import MapKit
import SwiftUI

/// A learned place's pin; the marker size follows the time spent there.
final class PlaceAnnotation: MKPointAnnotation {
    var placeId: Int64 = 0
    var totalSeconds = 0.0
}

struct TrackMapView: UIViewRepresentable {
    let data: MapData?
    let mode: MapMode
    let colour: LineColour
    let dark: Bool
    let satellite: Bool
    let visible: Bool
    let onRegion: @MainActor (MKCoordinateRegion, Double) -> Void   // region, view width in points
    let onPlace: @MainActor (Int64) -> Void
    var target: MKMapRect? = nil                 // set to fly the map there once
    var onLayers: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static var standard: MKStandardMapConfiguration {
        let c = MKStandardMapConfiguration(emphasisStyle: .muted)
        c.pointOfInterestFilter = .excludingAll
        return c
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = Self.standard   // muted, so LifePath's own layers carry the colour
        // The three layers live as long as the map; only their content changes.
        let c = context.coordinator
        map.addOverlay(c.streets, level: .aboveRoads)
        map.addOverlay(c.heat, level: .aboveRoads)
        map.addOverlay(c.fog, level: .aboveLabels)
        map.addOverlay(c.lines, level: .aboveLabels)
        map.showsCompass = false   // the column below owns the compass, so it never overlaps the locate button
        // One column, top right: layers, locate, compass (only when rotated); fixed 8 pt gaps.
        let layers = UIButton(type: .system, primaryAction: UIAction { [weak c] _ in c?.parent.onLayers() })
        layers.setImage(UIImage(systemName: "square.3.layers.3d"), for: .normal)
        layers.accessibilityLabel = "Map layers"
        let locate = MKUserTrackingButton(mapView: map)
        locate.accessibilityLabel = "Locate me"
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        for v in [layers, locate] as [UIView] {
            v.tintColor = UIColor(Palette.satsuma)
            v.widthAnchor.constraint(equalToConstant: 44).isActive = true
            v.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        // Layers and locate share one glass capsule (system Liquid Glass); the compass sits below it when the map is rotated.
        let pair = UIStackView(arrangedSubviews: [layers, locate])
        pair.axis = .vertical
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.layer.cornerRadius = 22; glass.layer.cornerCurve = .continuous; glass.clipsToBounds = true
        pair.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(pair)
        NSLayoutConstraint.activate([
            pair.topAnchor.constraint(equalTo: glass.contentView.topAnchor), pair.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            pair.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor), pair.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        let column = UIStackView(arrangedSubviews: [glass, compass])
        column.axis = .vertical; column.spacing = 8; column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if map.showsUserLocation != visible { map.showsUserLocation = visible }   // location only while on screen
        if let target, !(c.flown.map { MKMapRectEqualToRect($0, target) } ?? false) {
            c.flown = target
            map.setVisibleMapRect(target, edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 160, right: 20), animated: true)
        }
        if (map.preferredConfiguration is MKImageryMapConfiguration) != satellite {
            map.preferredConfiguration = satellite ? MKImageryMapConfiguration() : Self.standard
        }
        guard let data, data.generation != c.shownGeneration || colour != c.shownColour || dark != c.shownDark else { return }
        c.shownGeneration = data.generation
        c.shownColour = colour
        c.shownDark = dark
        func keyed(_ items: [(key: String, coords: [(lat: Double, lon: Double)])]) -> [(key: String, rect: MKMapRect, coords: [(lat: Double, lon: Double)])] {
            items.map { ($0.key, mapRect($0.coords, pad: 2000), $0.coords) }
        }
        c.streetsRenderer.set(mode == .streets ? StreetsContent(
            walked: keyed(data.covered), unwalked: keyed(data.unwalked),
            shading: data.shading.map { ($0.key, mapRect($0.rings.flatMap { $0 }, pad: 0), $0.rings, $0.holes, $0.share) }, dark: dark) : nil)
        c.fogRenderer.set(mode == .fog ? FogContent(data.fog, dark: dark) : nil)
        c.heatRenderer.set(mode == .heat ? HeatContent(data.heatLines, places: data.heatPlaces, max: data.heatMax, dark: dark) : nil)
        c.linesRenderer.set(LinesContent(data.lines, colour: colour, edged: mode == .streets, dark: dark))
        // Overlays are keyed: unchanged ones stay on the map, new ones are added before stale ones go, so nothing blinks.
        var wanted: [(key: String, level: MKOverlayLevel, make: () -> MKOverlay)] = []
        for (id, cells) in data.outlines {
            wanted.append(("o\(id)-\(cells.hashValue)-\(dark)", .aboveRoads, {
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
        for p in data.still {
            wanted.append(("s\(p.lat),\(p.lon)-\(dark)", .aboveLabels, { MKCircle(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), radius: 3) }))
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
        var shownColour = LineColour.plain
        var shownDark = false
        var flown: MKMapRect?
        let streets = LayerOverlay(), fog = LayerOverlay(), lines = LayerOverlay(), heat = LayerOverlay()
        lazy var heatRenderer = LayerRenderer(overlay: heat)
        lazy var streetsRenderer = LayerRenderer(overlay: streets)
        lazy var fogRenderer = LayerRenderer(overlay: fog)
        lazy var linesRenderer = LayerRenderer(overlay: lines)
        var shown: [String: MKOverlay] = [:]   // overlays on the map by key
        private var centered = false

        init(_ parent: TrackMapView) { self.parent = parent }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            let named = map.region.span.latitudeDelta < 0.15   // names from city zoom inward
            for a in map.annotations { (map.view(for: a) as? PlaceMarkerView)?.label.isHidden = !named }
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
            let v = map.dequeueReusableAnnotationView(withIdentifier: "place") as? PlaceMarkerView
                ?? PlaceMarkerView(annotation: a, reuseIdentifier: "place")
            v.annotation = a
            v.show(name: a.title, size: a.totalSeconds < 10 * 3600 ? 9 : a.totalSeconds < 100 * 3600 ? 11 : 13,
                   named: map.region.span.latitudeDelta < 0.15)
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
            if overlay === streets { return streetsRenderer }
            if overlay === fog { return fogRenderer }
            if overlay === lines { return linesRenderer }
            if let shape = overlay as? MKMultiPolygon {
                let r = MKMultiPolygonRenderer(multiPolygon: shape)
                r.fillColor = UIColor(Palette.text).withAlphaComponent(0.12)
                return r
            }
            if overlay === heat { return heatRenderer }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor = UIColor(Palette.muted)
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// A saved place: a small ink square on a paper edge, its name below from city zoom inward.
final class PlaceMarkerView: MKAnnotationView {
    let square = UIView(), label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required   // every place at every zoom
        square.backgroundColor = UIColor(Palette.text)
        square.layer.borderColor = UIColor(Palette.card).cgColor
        square.layer.borderWidth = 2
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(Palette.text)
        label.textAlignment = .center
        addSubview(square); addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func show(name: String?, size: CGFloat, named: Bool) {
        label.text = name
        label.isHidden = !named
        label.sizeToFit()
        let w = max(size, label.bounds.width)
        frame = CGRect(x: 0, y: 0, width: w, height: size + 2 + label.bounds.height)
        square.frame = CGRect(x: (w - size) / 2, y: 0, width: size, height: size)
        label.frame = CGRect(x: 0, y: size + 2, width: w, height: label.bounds.height)
        centerOffset = CGPoint(x: 0, y: (label.bounds.height + 2) / 2)   // the square sits on the place
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        square.layer.borderColor = UIColor(Palette.card).cgColor   // a CGColor does not follow the appearance by itself
    }
}
