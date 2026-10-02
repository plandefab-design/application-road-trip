import PDFKit
import SwiftUI
import TripCore
import UIKit
import XCTest
@testable import MotoTrip

/// The road book PDF on an iPhone simulator, as the rider gets it: the file has pages, and the viewer shows a white
/// page in the dark theme (not an empty dark screen). Synthetic trip only.
@MainActor
final class RoadBookPDFTests: XCTestCase {
    /// Two stages going north from a made-up start, with a chosen restaurant and hotel.
    static func trip() throws -> Trip {
        func line(from lat0: Double, km: Int) -> String {
            (0...km).map { String(format: "{\"lat\": %.5f, \"lon\": 6.00000}", lat0 + Double($0) / 111.2) }.joined(separator: ",")
        }
        let json = """
        {"schemaVersion": 8, "id": "test-pdf", "name": "Trip de test",
         "params": {"start": {"name": "Départ test", "point": {"lat": 44.0, "lon": 6.0}},
                    "dateStart": "2027-06-01", "dateEnd": "2027-06-02"},
         "days": [
           {"index": 1, "distanceKm": 120, "drivingTimeMin": 150, "from": "Départ test", "to": "Hôtel test",
            "highlights": [{"name": "Col test", "type": "pass", "point": {"lat": 44.5, "lon": 6.0}}],
            "track": {"points": [\(line(from: 44.0, km: 120))]},
            "meals": [{"poiId": "m1", "selected": true}], "lodging": [{"poiId": "h1", "selected": true}]},
           {"index": 2, "distanceKm": 90, "drivingTimeMin": 110,
            "track": {"points": [\(line(from: 45.08, km: 90))]}}
         ],
         "pois": [
           {"id": "m1", "type": "meal", "name": "Restaurant test", "point": {"lat": 44.6, "lon": 6.0}, "verification": "unverified"},
           {"id": "h1", "type": "lodging", "name": "Hôtel test", "point": {"lat": 45.08, "lon": 6.0}, "verification": "unverified"}
         ]}
        """
        return try TripCodec.decode(Data(json.utf8))
    }

    func render() async throws -> (url: URL, book: RoadBook) {
        let trip = try Self.trip()
        let book = RoadBook.build(trip, pace: PaceEstimator(), validatedAt: Date())
        return (await RoadBookPDF.render(book, trip: trip), book)
    }

    func testPDFHasNumberedPages() async throws {
        let (url, _) = try await render()
        XCTAssertEqual(url.pathExtension, "pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url), "unreadable PDF at \(url.path)")
        XCTAssertGreaterThan(doc.pageCount, 1)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("Trip de test"), "title missing")
        XCTAssertTrue(text.contains("Page 1 / \(doc.pageCount)"), "page numbers missing")
    }

    func testFileNameIsPlain() {
        XCTAssertEqual(RoadBookPDF.fileName("Alpes / Été 2027 : « cols »"), "Feuille de route - Alpes Été 2027 cols.pdf")
        XCTAssertEqual(RoadBookPDF.fileName("???"), "Feuille de route - trip.pdf")
    }

    /// What the rider sees: the viewer sheet's content in the dark theme shows the first page, fitted to the width.
    func testViewerShowsAWhitePage() async throws {
        let (url, _) = try await render()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: PDFViewer(url: url, title: "Feuille de route"))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var pdfView: FittingPDFView?
        for _ in 0..<40 where pdfView?.scaleFactor ?? 0 <= 0.1 {
            try await Task.sleep(for: .milliseconds(100))
            pdfView = Self.find(FittingPDFView.self, in: window)
        }
        let view = try XCTUnwrap(pdfView, "no PDF view on screen")
        XCTAssertGreaterThan(view.document?.pageCount ?? 0, 1)
        // A4 page (595 pt) fitted to a 393 pt wide screen.
        XCTAssertEqual(view.scaleFactor, (view.bounds.width - 12) / 595, accuracy: 0.02)

        try await Task.sleep(for: .seconds(1))           // page tiles drawn
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Self.keep(image, name: "pdf-viewer-dark")
        XCTAssertGreaterThan(Self.whiteFraction(image), 0.3, "the screen is not showing a white page")
    }

    // MARK: Helpers

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    /// Share of near-white pixels (sampled on a 60 × 120 grid).
    static func whiteFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = 60, h = 120
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var white = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] > 230 && pixels[i + 1] > 230 && pixels[i + 2] > 230 {
            white += 1
        }
        return Double(white) / Double(w * h)
    }

    /// Screenshot kept for the CI artifact (« MotoRoadTestShots » in the simulator's temporary folder).
    static func keep(_ image: UIImage, name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MotoRoadTestShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
