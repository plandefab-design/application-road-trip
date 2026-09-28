import Foundation
import TripCore

/// What happens when a ride ends, whatever the mode: km credited to « Ma moto » (maintenance alerts), ride saved.
@MainActor
enum RideFinish {
    static func record(_ ride: RideLog, settings: AppSettings, rides: RideStore, maintenance: MaintenanceStore) -> RideLog {
        var ride = ride
        if let bike = settings.primaryBike {
            ride.bikeId = bike.id
            _ = maintenance.book(for: bike)
            let newlyDue = maintenance.addRide(bikeId: bike.id, km: ride.summary.distance / 1000)
            Task { await Reminders.notifyMaintenance(bike: bike.model, items: newlyDue) }
        }
        rides.save(ride)
        return ride
    }
}
