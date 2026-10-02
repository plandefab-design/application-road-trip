import MapKit
import TripCore
import UIKit

/// Lays out a RoadBook as an A4 PDF in the style of a rider's « feuille de route »: orange kicker, navy titles with
/// an orange rule, timetables with a navy header and zebra rows, grey address cards, coloured boxes for the points
/// to check and the plan B, page header and « Page X / Y ». Maps are Apple Maps snapshots with the route drawn.
enum RoadBookPDF {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)      // A4 in points
    static let margin: CGFloat = 42
    static let top: CGFloat = 54                                        // below the page header
    static let bottom: CGFloat = 52                                     // above the footer
    static var width: CGFloat { page.width - 2 * margin }

    static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let navy = hex(0x1F2E4A), accent = hex(0xC1571A), ink = hex(0x222222), grey = hex(0x6B6B6B)
    static let zebra = hex(0xF2F2F2), cardFill = hex(0xF5F6F8), cardLine = hex(0xC9CDD6)
    static let route = UIColor(red: 1.00, green: 0.37, blue: 0.10, alpha: 1)

    static func tone(_ t: RoadBook.Tone) -> (fill: UIColor, text: UIColor) {
        switch t {
        case .warning: (hex(0xFCEFD8), hex(0x8A4B0F))
        case .ok: (hex(0xE7F3E8), hex(0x2E6B31))
        case .caution: (hex(0xFBE7DA), hex(0x9C5A16))
        case .danger: (hex(0xF8E3E1), hex(0x8C2B20))
        }
    }

    /// Writes the PDF to a temporary file named after the trip. Drawn on the main thread (UIKit text and shapes);
    /// a map that does not come within 10 s is left out (offline).
    @MainActor
    static func render(_ book: RoadBook, trip: Trip) async -> URL {
        var maps: [Int?: UIImage] = [:]
        for case .map(let day) in book.blocks {
            maps[day] = await snapshot(lines: lines(for: trip, day: day), size: CGSize(width: width, height: day == nil ? 250 : 170))
        }
        let data = pdfData(book, maps: maps)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FeuillesDeRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(trip.name))
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// The whole document. Two passes: the first counts the pages for « Page X / Y ».
    @MainActor
    static func pdfData(_ book: RoadBook, maps: [Int?: UIImage] = [:]) -> Data {
        let first = draw(book, maps: maps, total: nil)
        let second = draw(book, maps: maps, total: first.pages)
        return second.data.isEmpty ? first.data : second.data
    }

    /// One drawing of the book, each with its own renderer: a renderer used a second time gave an empty (0 byte)
    /// document, the unreadable road books of 1.0.52 and 1.0.53.
    @MainActor
    static func draw(_ book: RoadBook, maps: [Int?: UIImage], total: Int?) -> (data: Data, pages: Int) {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: book.title, kCGPDFContextCreator as String: "Moto Road"]
        var pages = 0
        let data = UIGraphicsPDFRenderer(bounds: page, format: format).pdfData { ctx in
            pages = layout(book, maps: maps, ctx: ctx, total: total)
        }
        return (data, pages)
    }

    /// « Feuille de route - Alpes 2027.pdf »: only letters, digits, spaces and dashes (any app opens it).
    static func fileName(_ tripName: String) -> String {
        let cleaned = String(tripName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
        return "Feuille de route - \(cleaned.isEmpty ? "trip" : String(cleaned.prefix(60))).pdf"
    }

    // MARK: Layout

    /// Draws every block; returns the number of pages.
    @discardableResult
    private static func layout(_ book: RoadBook, maps: [Int?: UIImage], ctx: UIGraphicsPDFRendererContext, total: Int?) -> Int {
        var y = top
        var pageNumber = 0

        func newPage() {
            ctx.beginPage()
            pageNumber += 1
            y = top
            text(book.header, .systemFont(ofSize: 8.5), grey, align: .right).draw(in: CGRect(x: margin, y: 22, width: width, height: 14))
            let foot = total.map { "Page \(pageNumber) / \($0)" } ?? "Page \(pageNumber)"
            text(foot, .systemFont(ofSize: 8.5), grey, align: .center).draw(in: CGRect(x: margin, y: page.height - 34, width: width, height: 14))
        }
        func room(_ h: CGFloat) -> Bool { y + h <= page.height - bottom }
        func ensure(_ h: CGFloat) { if !room(h) { newPage() } }
        func put(_ s: NSAttributedString, x: CGFloat = margin, w: CGFloat = width, after: CGFloat = 4) {
            let h = height(s, w)
            ensure(h)
            s.draw(with: CGRect(x: x, y: y, width: w, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += h + after
        }
        func rule(color: UIColor, thickness: CGFloat = 1.2) {
            color.setFill()
            UIRectFill(CGRect(x: margin, y: y, width: width, height: thickness))
            y += thickness + 6
        }

        // Rounded box with padding; moves to the next page when it does not fit.
        func box(_ body: NSAttributedString, fill: UIColor, line: UIColor?) {
            let pad: CGFloat = 10
            let h = height(body, width - 2 * pad) + 2 * pad
            ensure(h)
            let r = CGRect(x: margin, y: y, width: width, height: h)
            let path = UIBezierPath(roundedRect: r, cornerRadius: 6)
            fill.setFill()
            path.fill()
            if let line { line.setStroke(); path.lineWidth = 0.8; path.stroke() }
            body.draw(with: r.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += h + 10
        }

        // Navy header row, zebra rows, header repeated on a new page.
        func table(_ columns: [String], _ rows: [[String]]) {
            let ratios: [CGFloat] = columns.count == 4 ? [0.15, 0.43, 0.11, 0.31] : Array(repeating: 1 / CGFloat(columns.count), count: columns.count)
            let widths = ratios.map { $0 * width }
            let pad: CGFloat = 5
            func rowHeight(_ cells: [NSAttributedString]) -> CGFloat {
                zip(cells, widths).map { height($0, $1 - 2 * pad) }.max().map { $0 + 2 * pad } ?? 20
            }
            func draw(_ cells: [NSAttributedString], fill: UIColor, h: CGFloat) {
                fill.setFill()
                UIRectFill(CGRect(x: margin, y: y, width: width, height: h))
                var x = margin
                for (cell, w) in zip(cells, widths) {
                    cell.draw(with: CGRect(x: x + pad, y: y + pad, width: w - 2 * pad, height: h - 2 * pad),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    x += w
                }
                y += h
            }
            let header = columns.map { text($0, .systemFont(ofSize: 9, weight: .bold), .white) }
            let headerH = rowHeight(header)
            ensure(headerH + 24)
            draw(header, fill: navy, h: headerH)
            for (i, row) in rows.enumerated() {
                let cells = row.enumerated().map { j, s in
                    text(s, .systemFont(ofSize: 9, weight: j == 1 ? .semibold : .regular), j == 0 ? navy : ink)
                }
                let h = rowHeight(cells)
                if !room(h) {
                    newPage()
                    draw(header, fill: navy, h: headerH)
                }
                draw(cells, fill: i % 2 == 0 ? .white : zebra, h: h)
            }
            y += 10
        }

        newPage()
        for block in book.blocks {
            switch block {
            case .kicker(let s):
                put(text(s, .systemFont(ofSize: 10, weight: .heavy), accent, kern: 1.5), after: 2)
            case .title(let s):
                put(text(s, .systemFont(ofSize: 26, weight: .bold), navy), after: 2)
            case .subtitle(let s):
                put(text(s, .systemFont(ofSize: 13), hex(0x444444)), after: 14)
            case .heading(let s):
                ensure(70)
                y += 8
                put(text(s, .systemFont(ofSize: 15, weight: .bold), navy), after: 3)
                rule(color: accent)
            case .dayHeading(let s):
                ensure(120)
                y += 12
                put(text(s, .systemFont(ofSize: 13.5, weight: .bold), navy), after: 3)
                rule(color: accent)
            case .paragraph(let s):
                put(text(s, .systemFont(ofSize: 10), ink), after: 7)
            case .recap(let lines):
                let body = NSMutableAttributedString()
                for (i, l) in lines.enumerated() {
                    body.append(text(l + (i < lines.count - 1 ? "\n" : ""), .systemFont(ofSize: 12, weight: .bold), navy, align: .center, spacing: 4))
                }
                box(body, fill: cardFill, line: cardLine)
            case .callout(let t, let title, let lines, let bullets):
                let c = tone(t)
                let body = NSMutableAttributedString()
                if let title { body.append(text(title + "\n", .systemFont(ofSize: 11, weight: .bold), c.text, spacing: 4)) }
                for (i, l) in lines.enumerated() {
                    let last = i == lines.count - 1
                    body.append(text((bullets ? "•  " : "") + l + (last ? "" : "\n"), .systemFont(ofSize: 9.5), ink,
                                     spacing: 3, indent: bullets ? 12 : 0))
                }
                box(body, fill: c.fill, line: nil)
            case .table(let columns, let rows):
                table(columns, rows)
            case .card(let label, let title, let lines):
                let body = NSMutableAttributedString()
                body.append(text(label + "\n", .systemFont(ofSize: 9, weight: .bold), accent, spacing: 2))
                body.append(text(title + (lines.isEmpty ? "" : "\n"), .systemFont(ofSize: 11.5, weight: .bold), navy, spacing: 3))
                for (i, l) in lines.enumerated() {
                    body.append(text(l + (i == lines.count - 1 ? "" : "\n"), .systemFont(ofSize: 9.5), ink, spacing: 2))
                }
                box(body, fill: cardFill, line: cardLine)
            case .numbered(let items):
                for (i, item) in items.enumerated() {
                    put(text("\(i + 1).  \(item)", .systemFont(ofSize: 10), ink, indent: 16), after: 3)
                }
                y += 4
            case .bullets(let items):
                for item in items { put(text("•  \(item)", .systemFont(ofSize: 10), ink, indent: 12), after: 3) }
                y += 4
            case .facts(let facts):
                for f in facts {
                    let line = NSMutableAttributedString(attributedString: text("\(f.label)  ", .systemFont(ofSize: 9.5, weight: .semibold), grey))
                    line.append(text(f.value, .systemFont(ofSize: 10), ink))
                    put(line, after: 3)
                }
                y += 6
            case .map(let day):
                guard let image = maps[day] else { continue }        // offline: no map, text only
                let h = image.size.height * width / image.size.width
                ensure(h + 10)
                let r = CGRect(x: margin, y: y, width: width, height: h)
                image.draw(in: r)
                cardLine.setStroke()
                UIBezierPath(roundedRect: r, cornerRadius: 6).stroke()
                y += h + 10
            case .pageBreak:
                newPage()
            }
        }
        return pageNumber
    }

    private static func height(_ s: NSAttributedString, _ w: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    private static func text(_ s: String, _ font: UIFont, _ color: UIColor, align: NSTextAlignment = .left,
                             kern: CGFloat = 0, spacing: CGFloat = 0, indent: CGFloat = 0) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.alignment = align
        p.paragraphSpacing = spacing
        p.headIndent = indent
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern])
    }

    // MARK: Maps

    /// The whole trip (every day) or one day's track.
    private static func lines(for trip: Trip, day: Int?) -> [[GeoPoint]] {
        trip.days.filter { day == nil || $0.index == day }.compactMap { $0.track?.resampled(every: 300).points }
    }

    /// One snapshot, or nil after `timeout` seconds: the wait always ends (a cancelled snapshotter may never call
    /// back), so the PDF is never stuck on a map.
    @MainActor
    private static func shoot(_ options: MKMapSnapshotter.Options, timeout: TimeInterval) async -> MKMapSnapshotter.Snapshot? {
        final class Once { var done = false }
        let once = Once()
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            func finish(_ shot: MKMapSnapshotter.Snapshot?) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: shot)
            }
            snapshotter.start(with: .main) { shot, _ in finish(shot) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                snapshotter.cancel()
                finish(nil)
            }
        }
    }

    /// Apple Maps snapshot fitted to the lines, route drawn in orange. nil offline or without a track.
    @MainActor
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
        guard let shot = await shoot(options, timeout: 10) else { return nil }
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
                route.setStroke()
                path.stroke()
            }
        }
    }
}
