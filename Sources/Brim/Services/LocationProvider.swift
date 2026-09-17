import CoreLocation
import Foundation

/// One-shot location lookups. Lives outside the main actor because
/// CLLocationManager's delegate callbacks aren't isolated.
final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    typealias Completion = @Sendable (Result<CLLocationCoordinate2D, Error>) -> Void

    private let manager = CLLocationManager()
    private var pending: [Completion] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var statusDescription: String {
        "status=\(manager.authorizationStatus.rawValue) servicesEnabled=\(CLLocationManager.locationServicesEnabled())"
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    var isDenied: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: true
        default: !CLLocationManager.locationServicesEnabled()
        }
    }

    /// Call on the main thread.
    func requestLocation(_ completion: @escaping Completion) {
        pending.append(completion)
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            finish(.failure(CLError(.denied)))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !pending.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            break
        default:
            finish(.failure(CLError(.denied)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0(result) }
    }
}
