import Foundation
import Combine
import CoreLocation

@MainActor
final class LandingMapViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var userLocation: CLLocation?
    @Published var allMachines: [MachineLocation] = []
    @Published var nearbyMachines: [MachineLocation] = []
    @Published var isLoading: Bool = false
    @Published var errorText: String?

    private let locationManager = CLLocationManager()
    private let machineService: MachineLocatorService
    private let nearbyRadiusMeters: CLLocationDistance = 50_000

    init(machineService: MachineLocatorService = MachineLocatorService()) {
        self.machineService = machineService
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestLocationAccessIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .restricted, .denied:
            authorizationStatus = locationManager.authorizationStatus
        @unknown default:
            break
        }
    }

    func loadMachines() {
        Task {
            isLoading = true
            errorText = nil
            defer { isLoading = false }

            do {
                let machines = try await machineService.loadMachines()
                self.allMachines = machines
                filterNearbyMachines()
            } catch {
                self.errorText = error.localizedDescription
            }
        }
    }

    private func filterNearbyMachines() {
        guard let userLocation else {
            nearbyMachines = allMachines
            return
        }

        let withDistance = allMachines
            .map { ($0, $0.location.distance(from: userLocation)) }
            .sorted { $0.1 < $1.1 }

        let withinRadius = withDistance
            .filter { $0.1 <= nearbyRadiusMeters }
            .map(\.0)

        nearbyMachines = withinRadius.isEmpty ? withDistance.map(\.0) : withinRadius
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.last
        filterNearbyMachines()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorText = error.localizedDescription
    }
}

