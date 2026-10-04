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
    /// true = follow the rider, heading up, slightly tilted (navigation mode).
    var followUser = false
    /// Incremented by the « recentre » button: the map follows the rider again.
    var recenter = 0
    /// Optional detour route (« Autour de moi »), drawn in blue.
    var detour: [GeoPoint] = []
    /// Centre the map here (town zoom) whenever it changes: place picking, starting point.
    var focus: GeoPoint? = nil
    /// true = the view is fitted to the route once only (route editing: the map stays where the rider put it).
    var keepCamera = false
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
    /// Called with the map centre when the rider stops moving the map (place picking with a centre pin).
    var onCenterChange: ((GeoPoint) -> Void)? = nil
    /// Called with the touched place on a single tap of the map (not on a marker): route editing.
    var onTap: ((GeoPoint) -> Void)? = nil
    /// Rider option (Réglages › Navigation), off by default: the dark style has far fewer names and details.
    @AppStorage("mapDarkAtNight") private var darkAtNight = false

    private func styleURL(_ context: Context) -> URL {
        let dark = darkAtNight && context.environment.colorScheme == .dark
        return dark ? Self.darkStyleURL : Self.lightStyleURL
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL(context))
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.tintColor = Theme.uiAccent               // controls; the rider is drawn by MotoPuckView
        map.compassViewPosition = .topRight
        map.attributionButtonPosition = .bottomLeft
        map.logoView.isHidden = true
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            // A double tap still zooms: the single tap waits for it to fail.
            for case let other as UITapGestureRecognizer in map.gestureRecognizers ?? [] where other.numberOfTapsRequired == 2 {
                tap.require(toFail: other)
            }
            tap.delegate = context.coordinator
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let url = styleURL(context)
        if map.styleURL != url {
            context.coordinator.styleWillChange()
            map.styleURL = url
        }
        context.coordinator.onCenterChange = onCenterChange
        context.coordinator.onTap = onTap
        context.coordinator.apply(content, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        private var applied: MapContent?
        private var styleLoaded = false
        private var pending: MapContent?
        private var tilted = false
        private var lastRecenter = 0
        private var fitted = false
        /// The rider moved the map by hand: stop following until « recentrer » is pressed.
        private var userMovedMap = false
        var onCenterChange: ((GeoPoint) -> Void)?
        var onTap: ((GeoPoint) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MLNMapView, let onTap else { return }
            let at = gesture.location(in: map)
            // A tap on a marker opens its bubble, it does not add a point.
            let around = CGRect(x: at.x - 22, y: at.y - 22, width: 44, height: 44)
            if map.visibleAnnotations(in: around)?.contains(where: { !($0 is MLNUserLocation) }) == true { return }
            let c = map.convert(at, toCoordinateFrom: map)
            onTap(GeoPoint(lat: c.latitude, lon: c.longitude))
        }

        /// The map keeps its own taps (bubbles, deselection) alongside the editing tap.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            onCenterChange?(GeoPoint(lat: c.latitude, lon: c.longitude))
        }

        /// true while the map should follow the rider, oriented along the direction of travel.
        private var following = false

        /// Only a gesture of the rider stops the following; camera changes made by the app do not.
        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                    .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
            if following, !reason.isDisjoint(with: gestures) { userMovedMap = true }
        }

        /// MapLibre drops the course tracking on some camera updates: put it back unless the rider moved the map.
        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            guard following, !userMovedMap, mode != .followWithCourse else { return }
            DispatchQueue.main.async {
                mapView.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
            }
        }

        func styleWillChange() {
            styleLoaded = false
            pending = applied ?? pending
            applied = nil
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            if let p = pending { apply(p, to: mapView) }
        }

        /// Only what changed is redrawn: the ride's trace growing, a new way back or a radar coming into view no
        /// longer rebuild every route, dot and marker (smoother map, less battery while riding).
        func apply(_ content: MapContent, to map: MLNMapView) {
            guard styleLoaded, let style = map.style else { pending = content; return }
            guard content != applied else { return }
            let old = applied
            let geometryChanged = content.lines != old?.lines || content.markers != old?.markers
            let focusChanged = content.focus != nil && content.focus != old?.focus
            applied = content
            pending = nil

            if content.lines != old?.lines { updateLines(content.lines, old: old?.lines, style: style) }
            if old == nil || content.detour != old?.detour { updateDetour(content.detour, style: style) }
            if old == nil || content.alerts != old?.alerts || content.pauses != old?.pauses { updateDots(content, style: style) }
            if old == nil || content.markers != old?.markers { updateMarkers(content.markers, map: map) }

            // Camera
            following = content.followUser
            if content.followUser {
                let recentre = content.recenter != lastRecenter
                lastRecenter = content.recenter
                if recentre { userMovedMap = false }
                if !tilted || recentre {
                    tilted = true
                    // Street-level zoom and a light tilt first (a camera change cancels the tracking), then follow
                    // the rider with the map turned to the direction of travel, like a GPS.
                    let camera = map.camera
                    camera.pitch = 35
                    map.setCamera(camera, animated: false)
                    map.zoomLevel = 16
                    map.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
                } else if map.userTrackingMode != .followWithCourse && !userMovedMap {
                    map.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
                }
            } else if focusChanged, let f = content.focus {
                map.setCenter(CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), zoomLevel: 13, animated: false)
            } else if geometryChanged, !(content.keepCamera && fitted) {
                let all = content.lines.flatMap(\.points) + content.markers.map(\.point)
                fit(map, all)
                fitted = !all.isEmpty
            }
        }

        // MARK: Drawing (bottom to top: routes, detour, dots; markers are annotations above)

        private static let overlays = ["mt-detour-case", "mt-detour", "mt-dots-pause", "mt-dots-haz", "mt-dots-cam"]

        private func polyline(_ points: [GeoPoint]) -> MLNPolylineFeature {
            var coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        }

        /// Adds `layer` under the first existing layer of `above` (else on top), so the drawing order holds
        /// whatever is updated first.
        private func insert(_ layer: MLNStyleLayer, below above: [String], in style: MLNStyle) {
            if let anchor = above.lazy.compactMap({ style.layer(withIdentifier: $0) }).first {
                style.insertLayer(layer, below: anchor)
            } else {
                style.addLayer(layer)
            }
        }

        private func lineLayer(_ id: String, source: MLNSource, color: UIColor, width: Double) -> MLNLineStyleLayer {
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.lineColor = NSExpression(forConstantValue: color)
            layer.lineWidth = NSExpression(forConstantValue: width)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            return layer
        }

        /// Route lines: dark casing under a bright line, readable on any background; the highlighted ones on top.
        /// Same lines with new points (the ride's trace): the shapes are updated in place.
        private func updateLines(_ lines: [MapContent.Line], old: [MapContent.Line]?, style: MLNStyle) {
            let drawn = lines.filter { !$0.highlighted && $0.points.count > 1 } + lines.filter { $0.highlighted && $0.points.count > 1 }
            let layout = { (ls: [MapContent.Line]) in ls.map { "\($0.id)|\($0.highlighted)" } }
            if let old {
                let before = old.filter { !$0.highlighted && $0.points.count > 1 } + old.filter { $0.highlighted && $0.points.count > 1 }
                if layout(before) == layout(drawn) {
                    let previous = Dictionary(before.map { ($0.id, $0.points) }, uniquingKeysWith: { a, _ in a })
                    for line in drawn where previous[line.id] != line.points {
                        (style.source(withIdentifier: "mt-src-\(line.id)") as? MLNShapeSource)?.shape = polyline(line.points)
                    }
                    return
                }
            }
            for layer in style.layers where layer.identifier.hasPrefix("mt-line-") || layer.identifier.hasPrefix("mt-case-") {
                style.removeLayer(layer)
            }
            for source in style.sources where source.identifier.hasPrefix("mt-src-") { style.removeSource(source) }
            for line in drawn {
                let source = MLNShapeSource(identifier: "mt-src-\(line.id)", shape: polyline(line.points), options: nil)
                style.addSource(source)
                insert(lineLayer("mt-case-\(line.id)", source: source, color: UIColor(white: 0.08, alpha: line.highlighted ? 0.85 : 0.4),
                                 width: line.highlighted ? 10 : 6), below: Self.overlays, in: style)
                insert(lineLayer("mt-line-\(line.id)", source: source, color: line.highlighted ? Theme.uiAccent : .systemGray2,
                                 width: line.highlighted ? 6 : 3), below: Self.overlays, in: style)
            }
        }

        /// Detour, way back or free-ride route: blue line above the routes.
        private func updateDetour(_ points: [GeoPoint], style: MLNStyle) {
            let shape: MLNShape = points.count > 1 ? polyline(points) : MLNShapeCollectionFeature(shapes: [])
            if let source = style.source(withIdentifier: "mt-detour-src") as? MLNShapeSource {
                source.shape = shape
                return
            }
            guard points.count > 1 else { return }
            let source = MLNShapeSource(identifier: "mt-detour-src", shape: shape, options: nil)
            style.addSource(source)
            let dots = Array(Self.overlays.dropFirst(2))
            insert(lineLayer("mt-detour-case", source: source, color: UIColor(white: 0.08, alpha: 0.85), width: 10), below: dots, in: style)
            insert(lineLayer("mt-detour", source: source, color: .systemBlue, width: 6), below: dots, in: style)
        }

        /// Cameras (red), hazards (orange) and pause spots (green): one dot layer each, updated in place.
        private func updateDots(_ content: MapContent, style: MLNStyle) {
            let groups: [(id: String, points: [GeoPoint], color: UIColor, radius: Double)] = [
                ("mt-dots-pause", content.pauses, .systemGreen, 4),
                ("mt-dots-haz", content.alerts.filter { !$0.isCamera }.map(\.point), .systemOrange, 6),
                ("mt-dots-cam", content.alerts.filter(\.isCamera).map(\.point), .systemRed, 6),
            ]
            for group in groups {
                let features: [MLNPointFeature] = group.points.map { p in
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                    return f
                }
                let shape = MLNShapeCollectionFeature(shapes: features)
                if let source = style.source(withIdentifier: group.id) as? MLNShapeSource {
                    source.shape = shape
                    continue
                }
                guard !features.isEmpty else { continue }
                let source = MLNShapeSource(identifier: group.id, shape: shape, options: nil)
                style.addSource(source)
                let layer = MLNCircleStyleLayer(identifier: group.id, source: source)
                layer.circleColor = NSExpression(forConstantValue: group.color)
                layer.circleRadius = NSExpression(forConstantValue: group.radius)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 2)
                style.addLayer(layer)
            }
        }

        /// Markers: round emoji badges (see viewFor).
        private func updateMarkers(_ markers: [MapContent.Marker], map: MLNMapView) {
            if let old = map.annotations?.filter({ !($0 is MLNUserLocation) }) { map.removeAnnotations(old) }
            map.addAnnotations(markers.map { m in
                let a = MLNPointAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: m.point.lat, longitude: m.point.lon)
                a.title = m.title
                a.subtitle = m.subtitle
                return a
            })
        }

        private func fit(_ map: MLNMapView, _ pts: [GeoPoint]) {
            guard let first = pts.first else { return }
            var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
            for p in pts {
                minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
                minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
            }
            // A single place: show its surroundings (≈ 10 km) rather than the maximum zoom.
            let pad = max(0, 0.05 - (maxLat - minLat)) / 2, padLon = max(0, 0.07 - (maxLon - minLon)) / 2
            minLat -= pad; maxLat += pad; minLon -= padLon; maxLon += padLon
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                             ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 40, left: 30, bottom: 40, right: 30),
                                           animated: false, completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }

        /// The rider is a mini motorbike; markers are round badges with their emoji instead of the default pin.
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                return (mapView.dequeueReusableAnnotationView(withIdentifier: "moto") as? MotoPuckView)
                    ?? MotoPuckView(reuseIdentifier: "moto")
            }
            guard let point = annotation as? MLNPointAnnotation else { return nil }
            let icon = point.title?.first.map { $0.isLetter || $0.isNumber ? "📍" : String($0) } ?? "📍"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "emoji") as? EmojiAnnotationView)
                ?? EmojiAnnotationView(reuseIdentifier: "emoji")
            view.label.text = icon
            return view
        }
    }
}

/// The rider's position: a mini motorbike in an orange disc with a soft pulsing halo, and a chevron around it
/// pointing where the bike is heading (straight up when the map follows the course).
final class MotoPuckView: MLNUserLocationAnnotationView {
    private let halo = CALayer()
    private let disc = UIView()
    private let glyph = UIImageView()
    private let pointer = UIView()          // rotates around the centre
    private let chevron = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        let c = CGPoint(x: 36, y: 36)

        halo.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        halo.position = c
        halo.cornerRadius = 30
        halo.backgroundColor = Theme.uiAccent.withAlphaComponent(0.25).cgColor
        layer.addSublayer(halo)

        pointer.frame = bounds
        pointer.isUserInteractionEnabled = false
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 36, y: 2))
        path.addLine(to: CGPoint(x: 46, y: 16))
        path.addLine(to: CGPoint(x: 36, y: 12))
        path.addLine(to: CGPoint(x: 26, y: 16))
        path.close()
        chevron.path = path.cgPath
        chevron.fillColor = Theme.uiAccent.cgColor
        chevron.strokeColor = UIColor.white.cgColor
        chevron.lineWidth = 1.5
        chevron.lineJoin = .round
        pointer.layer.addSublayer(chevron)
        addSubview(pointer)

        disc.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
        disc.center = c
        disc.backgroundColor = Theme.uiAccent
        disc.layer.cornerRadius = 19
        disc.layer.borderColor = UIColor.white.cgColor
        disc.layer.borderWidth = 3
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.35
        disc.layer.shadowRadius = 4
        disc.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(disc)

        glyph.image = MotoGlyph.image(pointSize: 15)
        glyph.contentMode = .scaleAspectFit
        glyph.frame = disc.bounds.insetBy(dx: 6, dy: 8)
        disc.addSubview(glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, halo.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.75
        pulse.toValue = 1.15
        pulse.duration = 1.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(pulse, forKey: "pulse")
    }

    /// Called by the map when the position, heading or camera changes.
    override func update() {
        guard let map = mapView, let location = userLocation?.location else { return }
        let course = location.course >= 0 ? location.course : userLocation?.heading?.trueHeading
        pointer.isHidden = course == nil
        if let course {
            let angle = (course - map.direction) * .pi / 180
            pointer.transform = CGAffineTransform(rotationAngle: angle)
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
        layer.borderColor = Theme.uiAccent.cgColor
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
