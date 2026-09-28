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
        let title: String
        let subtitle: String?
    }
    var lines: [Line] = []
    var markers: [Marker] = []
    /// Speed cameras (red) and hazards (orange), drawn as dots in their own layers.
    var alerts: [AlertDot] = []
    /// true = follow the rider with heading-up camera (navigation mode).
    var followUser = false
}

extension MapContent {
    static func from(trip: Trip, highlightDay: Int? = nil) -> MapContent {
        var c = MapContent()
        for day in trip.days {
            if let t = day.track, !t.isEmpty {
                c.lines.append(.init(id: "day\(day.index)", points: t.points, highlighted: highlightDay == nil || highlightDay == day.index))
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
        }
        for poi in trip.pois {
            if let p = poi.point {
                let status = poi.verification == .verified ? "vérifié" : "non vérifié"
                c.markers.append(.init(id: poi.id, point: p, title: poi.name, subtitle: status))
            }
        }
        return c
    }
}

/// MapLibre adapter. Style: OpenFreeMap (free, no key) until offline PMTiles packs land (spike S2).
struct TripMapView: UIViewRepresentable {
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    var content: MapContent

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.compassViewPosition = .topRight
        map.attributionButtonPosition = .bottomLeft
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.apply(content, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var applied: MapContent?
        private var styleLoaded = false
        private var pending: MapContent?

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

            // Lines
            for layer in style.layers where layer.identifier.hasPrefix("mt-line-") { style.removeLayer(layer) }
            for source in style.sources where source.identifier.hasPrefix("mt-src-") { style.removeSource(source) }
            for line in content.lines where line.points.count > 1 {
                var coords = line.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                let source = MLNShapeSource(identifier: "mt-src-\(line.id)", shape: feature, options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: "mt-line-\(line.id)", source: source)
                layer.lineColor = NSExpression(forConstantValue: line.highlighted ? UIColor.systemOrange : UIColor.systemGray)
                layer.lineWidth = NSExpression(forConstantValue: line.highlighted ? 6 : 3)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }

            // Speed cameras and hazards: dots in two layers (constant colors, no expression needed).
            for id in ["mt-alerts-cam", "mt-alerts-haz"] {
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            for (id, isCamera, color) in [("mt-alerts-cam", true, UIColor.systemRed), ("mt-alerts-haz", false, UIColor.systemOrange)] {
                let features: [MLNPointFeature] = content.alerts.filter { $0.isCamera == isCamera }.map { a in
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: a.point.lat, longitude: a.point.lon)
                    return f
                }
                guard !features.isEmpty else { continue }
                let source = MLNShapeSource(identifier: id, features: features, options: nil)
                style.addSource(source)
                let layer = MLNCircleStyleLayer(identifier: id, source: source)
                layer.circleColor = NSExpression(forConstantValue: color)
                layer.circleRadius = NSExpression(forConstantValue: 6)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 2)
                style.addLayer(layer)
            }

            // Markers
            if let old = map.annotations { map.removeAnnotations(old) }
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
    }
}
