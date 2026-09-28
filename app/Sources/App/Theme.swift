import SwiftUI
import UIKit

/// MotoTrip look, one product everywhere: carbon black, racing orange, smoked-glass panels, heavy rounded type.
enum Theme {
    static let accent = Color(red: 1.00, green: 0.37, blue: 0.10)      // racing orange #FF5E1A
    static let accentHot = Color(red: 1.00, green: 0.16, blue: 0.33)   // hot red #FF2954
    static let carbon = Color(red: 0.047, green: 0.051, blue: 0.063)   // #0C0D10
    static let graphite = Color(red: 0.105, green: 0.113, blue: 0.137) // #1B1D23
    static let muted = Color.white.opacity(0.62)
    static let camera = Color(red: 0.96, green: 0.17, blue: 0.24)
    static let hazard = Color(red: 1.00, green: 0.64, blue: 0.00)
    static let info = Color(red: 0.26, green: 0.56, blue: 1.00)
    static let ok = Color(red: 0.19, green: 0.84, blue: 0.52)

    static let uiAccent = UIColor(red: 1.00, green: 0.37, blue: 0.10, alpha: 1)

    static let rideGradient = LinearGradient(colors: [accent, accentHot], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = LinearGradient(colors: [graphite, carbon], startPoint: .top, endPoint: .bottom)

    /// « MOTO TRIP » wordmark: heavy italic, TRIP in orange.
    static func wordmark(size: CGFloat = 30) -> some View {
        (Text("MOTO").foregroundColor(.white) + Text("TRIP").foregroundColor(accent))
            .font(.system(size: size, weight: .black, design: .rounded).italic())
            .tracking(1)
    }
}

/// Smoked-glass panel used over the map and on the home screen (always dark, readable in the sun).
struct GlassPanel: ViewModifier {
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill((tint ?? .black).opacity(tint == nil ? 0.45 : 0.82))
                    shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            }
    }
}

extension View {
    func glass(radius: CGFloat = 22, tint: Color? = nil) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint))
    }
}

/// Round glass button over the map (big target for gloves).
struct MapRoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .bold))
                .frame(width: 56, height: 56)
                .glass(radius: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Mini motorbike: the SF Symbol when the system has it, else a drawn silhouette (same look in UIKit and SwiftUI).
enum MotoGlyph {
    static func image(pointSize: CGFloat, color: UIColor = .white) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        for name in ["motorcycle.fill", "motorcycle"] {
            if let symbol = UIImage(systemName: name, withConfiguration: config) {
                return symbol.withTintColor(color, renderingMode: .alwaysOriginal)
            }
        }
        return drawn(size: CGSize(width: pointSize * 1.6, height: pointSize), color: color)
    }

    /// Side view: two wheels, frame, tank, seat and handlebar.
    private static func drawn(size: CGSize, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let w = size.width, h = size.height
            let r = h * 0.26, line = max(1.5, h * 0.1)
            color.setStroke()
            color.setFill()
            for cx in [r + line, w - r - line] {
                let wheel = UIBezierPath(ovalIn: CGRect(x: cx - r, y: h - 2 * r - line / 2, width: 2 * r, height: 2 * r))
                wheel.lineWidth = line
                wheel.stroke()
            }
            let body = UIBezierPath()
            body.move(to: CGPoint(x: r + line, y: h - r - line / 2))                 // rear axle
            body.addLine(to: CGPoint(x: w * 0.42, y: h * 0.45))                      // swingarm to engine
            body.addLine(to: CGPoint(x: w * 0.62, y: h * 0.45))
            body.addLine(to: CGPoint(x: w - r - line, y: h - r - line / 2))          // fork to front axle
            body.move(to: CGPoint(x: w * 0.2, y: h * 0.38))                          // seat
            body.addLine(to: CGPoint(x: w * 0.45, y: h * 0.38))
            body.move(to: CGPoint(x: w * 0.66, y: h * 0.52))                         // fork up to the bar
            body.addLine(to: CGPoint(x: w * 0.72, y: h * 0.12))
            body.addLine(to: CGPoint(x: w * 0.84, y: h * 0.12))
            body.lineWidth = line
            body.lineCapStyle = .round
            body.lineJoinStyle = .round
            body.stroke()
            UIBezierPath(roundedRect: CGRect(x: w * 0.42, y: h * 0.28, width: w * 0.22, height: h * 0.2), cornerRadius: h * 0.08).fill()
        }
    }
}

struct MotoGlyphView: View {
    var size: CGFloat = 22
    var color: Color = .white

    var body: some View {
        Image(uiImage: MotoGlyph.image(pointSize: size, color: UIColor(color)))
            .accessibilityHidden(true)
    }
}
