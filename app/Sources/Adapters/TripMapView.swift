import CoreLocation
import MapLibre
import SwiftUI
import TripCore
import UIKit

/// What the map should draw. Views only talk to this type, never to MapLibre directly (CLAUDE.md rule 4).
struct MapContent: Equatable {
    struct Line: Equatable {
        let id: String
        let points: [GeoPoint]
        let highlighted: Bool
    }
    struct AlertDot: Equatable {
        let point: GeoPoint
        let isCamera: Bool
    }
    struct Marker: Equatable {
        let id: String
        let point: GeoPoint
        /// Starts with an emoji used as the round icon (« ⛽ Station », « 🏁 Arrivée »…).
        let title: String
        let subtitle: String?
    }
    var lines: [Line] = []
    var markers: [Marker] = []
    /// Speed cameras (red) and hazards (orange), drawn as dots in their own layers.
    var alerts: [AlertDot] = []
    /// Suggested pause spots (green dots) of the selected day.
    var pauses: [GeoPoint] = []
    /// true = follow the rider, heading up, tilted 3D view (navigation mode).
    var followUser = false
}

extension MapContent {
    static func from(trip: Trip, highlightDay: Int? = nil) -> MapContent {
        var c = MapContent()
        for day in trip.days {
            let focused = highlightDay == nil || highlightDay == day.index
            if let t = day.track, !t.isEmpty {
                c.lines.append(.init(id: "day\(day.index)", points: t.points, highlighted: focused))
                // Start / finish of the day (only for the focused day, or a single-day trip, to stay readable).
                if highlightDay == day.index || trip.days.count == 1, let first = t.points.first, let last = t.points.last {
                    c.markers.append(.init(id: "start-\(day.index)", point: first, title: "🏍 Départ jour \(day.index)", subtitle: nil))
                    c.markers.append(.init(id: "end-\(day.index)", point: last, title: "🏁 Arrivée jour \(day.index)", subtitle: nil))
                }
            }
            for f in day.fuelStops {
                c.markers.append(.init(id: "fuel-\(day.index)-\(f.kmFromStart)", point: f.point, title: "⛽ \(f.name)", subtitle: "km \(Int(f.kmFromStart))"))
            }
            for h in day.highlights {
                if let p = h.point { c.markers.append(.init(id: "hl-\(day.index)-\(h.name)", point: p, title: "⛰ \(h.name)", subtitle: nil)) }
            }
            for a in day.alerts {
                if let p = a.point { c.alerts.append(.init(point: p, isCamera: a.kind.isCamera)) }
            }
            if highlightDay == day.index {
                c.pauses += day.pauses.compactMap(\.point)
            }
        }
        for poi in trip.pois {
            if let p = poi.point {
                let status = poi.verification == .verified ? "vérifié" : "non vérifié"
                c.markers.append(.init(id: poi.id, point: p, title: "\(icon(poi.type)) \(poi.name)", subtitle: status))
            }
        }
        return c
    }

    static func icon(_ type: POIType) -> String {
        switch type {
        case .meal: "🍴"
        case .lodging: "🛏"
        case .fuel: "⛽"
        case .pass: "⛰"
        case .viewpoint: "👁"
        }
    }
}

/// MapLibre adapter. OpenFreeMap styles (free, no key): Liberty by day, Dark at night and while riding.
/// Both use the same tiles, so the offline packs of both styles share them.
struct TripMapView: UIViewRepresentable {
    static let lightStyleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    static let darkStyleURL = URL(string: "https://tiles.openfreemap.org/styles/dark")!
    static var allStyleURLs: [URL] { [lightStyleURL, darkStyleURL] }

    var content: MapContent
    /// nil = follow the system appearance; riding screens force dark.
    var forceDark: Bool? = nil

    private func styleURL(_ context: Context) -> URL {
        let dark = forceDark ?? (content.followUser || context.environment.colorScheme == .dark)
        return dark ? Self.darkStyleURL : Self.lightStyleURL
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL(context))
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.tintColor = .systemOrange                 // rider position and heading
        map.compassViewPosition = .topRight
        map.attributionButtonPosition = .bottomLeft
        map.logoView.isHidden = true
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let url = styleURL(context)
        if map.styleURL != url {
            context.coordinator.styleWillChange()
            map.styleURL = url
        }
        context.coordinator.apply(content, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var applied: MapContent?
        private var styleLoaded = false
        private var pending: MapContent?
        private var tilted = false

        func styleWillChange() {
            styleLoaded = false
            pending = applied ?? pending
            applied = nil
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            if let p = pending { apply(p, to: mapView) }
        }

        func apply(_ content: MapContent, to map: MLNMapView) {
            guard styleLoaded, let style = map.style else { pending = content; return }
            guard content != applied else { return }
            let geometryChanged = content.lines != applied?.lines
            applied = content
            pending = nil

            // Route lines: dark casing under a bright line, readable on any background.
            for layer in style.layers where layer.identifier.hasPrefix("mt-line-") || layer.identifier.hasPrefix("mt-case-") {
                style.removeLayer(layer)
            }
            for source in style.sources where source.identifier.hasPrefix("mt-src-") { style.removeSource(source) }
            for line in content.lines.sorted(by: { !$0.highlighted && $1.highlighted }) where line.points.count > 1 {
                var coords = line.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                let source = MLNShapeSource(identifier: "mt-src-\(line.id)", shape: feature, options: nil)
                style.addSource(source)
                let casing = MLNLineStyleLayer(identifier: "mt-case-\(line.id)", source: source)
                casing.lineColor = NSExpression(forConstantValue: UIColor(white: 0.08, alpha: line.highlighted ? 0.85 : 0.4))
                casing.lineWidth = NSExpression(forConstantValue: line.highlighted ? 10 : 6)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)
                let layer = MLNLineStyleLayer(identifier: "mt-line-\(line.id)", source: source)
                layer.lineColor = NSExpression(forConstantValue: line.highlighted ? UIColor.systemOrange : UIColor.systemGray2)
                layer.lineWidth = NSExpression(forConstantValue: line.highlighted ? 6 : 3)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }

            // Cameras, hazards and pause spots: dots in their own layers (constant colors, no expression needed).
            let dotLayers: [(id: String, points: [GeoPoint], color: UIColor, radius: Double)] = [
                ("mt-dots-pause", content.pauses, .systemGreen, 4),
                ("mt-dots-haz", content.alerts.filter { !$0.isCamera }.map(\.point), .systemOrange, 6),
                ("mt-dots-cam", content.alerts.filter(\.isCamera).map(\.point), .systemRed, 6),
            ]
            for dots in dotLayers {
                if let layer = style.layer(withIdentifier: dots.id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: dots.id) { style.removeSource(source) }
                guard !dots.points.isEmpty else { continue }
                let features: [MLNPointFeature] = dots.points.map { p in
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                    return f
                }
                let source = MLNShapeSource(identifier: dots.id, features: features, options: nil)
                style.addSource(source)
                let layer = MLNCircleStyleLayer(identifier: dots.id, source: source)
                layer.circleColor = NSExpression(forConstantValue: dots.color)
                layer.circleRadius = NSExpression(forConstantValue: dots.radius)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 2)
                style.addLayer(layer)
            }

            // Markers (round emoji icons, see viewFor)
            if let old = map.annotations?.filter({ !($0 is MLNUserLocation) }) { map.removeAnnotations(old) }
            let annotations: [MLNPointAnnotation] = content.markers.map { m in
                let a = MLNPointAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: m.point.lat, longitude: m.point.lon)
                a.title = m.title
                a.subtitle = m.subtitle
                return a
            }
            map.addAnnotations(annotations)

            // Camera
            if content.followUser {
                map.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
                if !tilted {
                    tilted = true
                    let camera = map.camera
                    camera.pitch = 50                          // « 3D » riding view
                    map.setCamera(camera, animated: true)
                }
            } else if geometryChanged {
                let all = content.lines.flatMap(\.points) + content.markers.map(\.point)
                fit(map, all)
            }
        }

        private func fit(_ map: MLNMapView, _ pts: [GeoPoint]) {
            guard let first = pts.first else { return }
            var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
            for p in pts {
                minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
                minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
            }
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                             ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 40, left: 30, bottom: 40, right: 30),
                                           animated: false, completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }

        /// Round white badge with the marker's emoji instead of the default pin.
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let point = annotation as? MLNPointAnnotation else { return nil }
            let icon = point.title?.first.map { $0.isLetter || $0.isNumber ? "📍" : String($0) } ?? "📍"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "emoji") as? EmojiAnnotationView)
                ?? EmojiAnnotationView(reuseIdentifier: "emoji")
            view.label.text = icon
            return view
        }
    }
}

/// 34 pt round badge with an emoji, white background, orange ring and a soft shadow.
final class EmojiAnnotationView: MLNAnnotationView {
    let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        backgroundColor = .white
        layer.cornerRadius = 17
        layer.borderColor = UIColor.systemOrange.cgColor
        layer.borderWidth = 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 18)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
