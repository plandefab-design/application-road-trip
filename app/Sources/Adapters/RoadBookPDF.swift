import MapKit
import TripCore
import UIKit

/// Lays out a RoadBook as an A4 PDF: text blocks, the whole trip's map and one map per stage (Apple Maps
/// snapshots with the route drawn). Built on the iPhone, no network needed except for the map tiles.
enum RoadBookPDF {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)      // A4 in points
    static let margin: CGFloat = 40
    static let accent = UIColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 1)

    /// Writes the PDF to a temporary file named after the trip.
    static func render(_ book: RoadBook, trip: Trip) async -> URL {
        var maps: [Int?: UIImage] = [:]
        for case .map(let day) in book.blocks {
            maps[day] = await snapshot(lines: lines(for: trip, day: day), size: CGSize(width: page.width - 2 * margin, height: day == nil ? 300 : 220))
        }
        let safeName = trip.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName) — cahier des charges.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: book.title, kCGPDFContextCreator as String: "Moto Road"]
            return f
        }())
        try? renderer.writePDF(to: url) { ctx in
            var y = margin
            var pageNumber = 0
            let width = page.width - 2 * margin

            func newPage() {
                ctx.beginPage()
                pageNumber += 1
                y = margin
                footer(pageNumber, title: book.title)
            }
            func ensure(_ height: CGFloat) { if y + height > page.height - margin - 20 { newPage() } }
            func draw(_ text: NSAttributedString, spacingAfter: CGFloat = 6) {
                let h = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
                ensure(h)
                text.draw(with: CGRect(x: margin, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += h + spacingAfter
            }

            newPage()
            draw(styled(book.title, .systemFont(ofSize: 26, weight: .heavy)), spacingAfter: 2)
            draw(styled(book.subtitle, .systemFont(ofSize: 13, weight: .medium), color: .darkGray), spacingAfter: 14)

            for block in book.blocks {
                switch block {
                case .heading(let text):
                    ensure(60)                                    // never a heading alone at the bottom
                    y += 6
                    draw(styled(text, .systemFont(ofSize: 17, weight: .bold), color: accent), spacingAfter: 6)
                case .facts(let facts):
                    for f in facts {
                        let line = NSMutableAttributedString(attributedString: styled("\(f.label)  ", .systemFont(ofSize: 11, weight: .semibold), color: .darkGray))
                        line.append(styled(f.value, .systemFont(ofSize: 12)))
                        draw(line, spacingAfter: 3)
                    }
                    y += 6
                case .bullets(let items):
                    for item in items { draw(styled("•  \(item)", .systemFont(ofSize: 12)), spacingAfter: 3) }
                    y += 6
                case .paragraph(let text):
                    draw(styled(text, .italicSystemFont(ofSize: 11), color: .darkGray), spacingAfter: 8)
                case .map(let day):
                    guard let image = maps[day] else { continue }        // offline: no map, text only
                    let h = image.size.height * width / image.size.width
                    ensure(h + 8)
                    image.draw(in: CGRect(x: margin, y: y, width: width, height: h))
                    UIColor.lightGray.setStroke()
                    UIBezierPath(roundedRect: CGRect(x: margin, y: y, width: width, height: h), cornerRadius: 6).stroke()
                    y += h + 10
                case .pageBreak:
                    newPage()
                }
            }
        }
        return url
    }

    private static func footer(_ number: Int, title: String) {
        let text = styled("\(title) · Moto Road · page \(number)", .systemFont(ofSize: 9), color: .gray)
        text.draw(at: CGPoint(x: margin, y: page.height - margin + 8))
    }

    private static func styled(_ text: String, _ font: UIFont, color: UIColor = .black) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    // MARK: Maps

    /// The whole trip (every day) or one day's track.
    private static func lines(for trip: Trip, day: Int?) -> [[GeoPoint]] {
        trip.days.filter { day == nil || $0.index == day }.compactMap { $0.track?.resampled(every: 300).points }
    }

    /// Apple Maps snapshot fitted to the lines, route drawn in orange. nil offline or without a track.
    private static func snapshot(lines: [[GeoPoint]], size: CGSize) async -> UIImage? {
        let all = lines.flatMap { $0 }
        guard all.count >= 2 else { return nil }
        let lats = all.map(\.lat), lons = all.map(\.lon)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.25),
                                    longitudeDelta: max(0.02, (lons.max()! - lons.min()!) * 1.25))
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        options.scale = 2
        options.pointOfInterestFilter = .excludingAll
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in
            shot.image.draw(at: .zero)
            for line in lines {
                let path = UIBezierPath()
                for (i, p) in line.enumerated() {
                    let pt = shot.point(for: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.lineWidth = 5
                path.lineJoinStyle = .round
                UIColor.white.setStroke()
                path.stroke()
                path.lineWidth = 3
                accent.setStroke()
                path.stroke()
            }
        }
    }
}
