import CoreMotion
import SwiftUI
import TripCore

/// Lean angle while riding: the gyroscope's rate of turn around the vertical (25 times a second) and the GPS speed
/// feed TripCore's LeanTracker. No permission is asked (raw motion data needs none). The screen is refreshed
/// 5 times a second at most, and only the badge observes it.
@MainActor
final class LeanMeter: ObservableObject {
    /// Smoothed angle in whole degrees, negative = leaning left.
    @Published private(set) var angle = 0.0
    private let motion = CMMotionManager()
    private var tracker = LeanTracker()
    private var speed = 0.0
    private var lastShown: TimeInterval = 0

    var available: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 25
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let g = data.gravity, r = data.rotationRate
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 0.5 else { return }
            // Gravity points down: the rate of turn around the up axis is minus its projection on gravity, whatever
            // the way the phone is mounted.
            let yawRate = -(r.x * g.x + r.y * g.y + r.z * g.z) / norm
            MainActor.assumeIsolated { self?.sample(yawRate: yawRate, time: data.timestamp) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        angle = 0
    }

    /// Latest GPS speed, m/s (negative = unknown).
    func setSpeed(_ metresPerSecond: Double) {
        speed = max(0, metresPerSecond)
    }

    /// The ride's lean statistics (nil without a gyroscope).
    var summary: LeanSummary? { available ? tracker.summary : nil }

    private func sample(yawRate: Double, time: TimeInterval) {
        let current = tracker.update(speed: speed, yawRate: yawRate, time: time)
        guard time - lastShown >= 0.2 else { return }
        lastShown = time
        let shown = current.rounded()
        if shown != angle { angle = shown }
    }
}

/// The bike seen from behind, tilted by the lean angle, and the angle in degrees (G / D).
struct LeanBadge: View {
    @ObservedObject var meter: LeanMeter

    var body: some View {
        let a = meter.angle
        HStack(spacing: 6) {
            Capsule()
                .fill(abs(a) >= 45 ? Theme.hazard : abs(a) >= 30 ? Theme.accent : .white)
                .frame(width: 6, height: 26)
                .rotationEffect(.degrees(a), anchor: .bottom)
                .animation(.easeOut(duration: 0.2), value: a)
            VStack(spacing: 0) {
                Text("\(Int(abs(a)))°").font(.title3.bold().monospacedDigit())
                Text(abs(a) < 3 ? "angle" : a < 0 ? "gauche" : "droite").font(.caption2.bold()).foregroundStyle(Theme.muted)
            }
        }
        .frame(minWidth: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Angle \(Int(abs(a))) degrés \(a < 0 ? "à gauche" : "à droite")")
    }
}
