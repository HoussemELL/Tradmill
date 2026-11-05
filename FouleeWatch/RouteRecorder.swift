import CoreLocation
import HealthKit

/// Tracé GPS d'un exercice en extérieur, enregistré par la montre seule (sans iPhone) et
/// rattaché à la séance Santé à la fin. Points imprécis (> 50 m) ignorés.
final class RouteRecorder: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var routeBuilder: HKWorkoutRouteBuilder?
    private(set) var pointCount = 0
    /// Dernière précision GPS reçue (m), pour l'affichage.
    private(set) var lastAccuracy: Double?

    func start(healthStore: HKHealthStore) {
        routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 3
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if routeBuilder != nil, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastAccuracy = locations.last?.horizontalAccuracy
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        guard !good.isEmpty, let rb = routeBuilder else { return }
        pointCount += good.count
        rb.insertRouteData(good) { _, _ in }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    var isAuthorized: Bool {
        location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways
    }

    /// Fin de l'exercice : tracé rattaché à la séance enregistrée (ou abandonné).
    func finish(with workout: HKWorkout?) {
        location.stopUpdatingLocation()
        guard let rb = routeBuilder else { return }
        routeBuilder = nil
        if let w = workout, pointCount > 1 {
            rb.finishRoute(with: w, metadata: nil) { _, _ in }
        } else {
            rb.discard()
        }
    }
}
