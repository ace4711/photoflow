import CoreLocation

/// Engångs-GPS-position för en fältanteckning. Fas 7 använder bara
/// "When In Use"-behörighet (`NSLocationWhenInUseUsageDescription`) och en
/// enda `requestLocation()` per anteckning — ingen bakgrundsspårning, ingen
/// kontinuerlig uppdatering, så batteripåverkan är minimal.
///
/// På Simulator ger `requestLocation()` bara en fix om en simulerad plats är
/// inställd (Debug → Location i Simulator-appen, eller
/// `xcrun simctl location`) — annars svarar den här tjänsten `nil` efter
/// `timeout` sekunder, och anteckningen sparas ändå utan position (se
/// `RecordButtonView`).
@MainActor
final class FieldLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var lastError: String?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorizationIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Väntar på en engångsposition, max `timeout` sekunder. Returnerar
    /// `nil` (aldrig ett fel som stoppar anteckningen) om behörighet saknas,
    /// tiden gick ut, eller platsen misslyckades.
    func currentLocation(timeout: TimeInterval = 8) async -> CLLocation? {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return nil }
        // Om ett tidigare anrop av någon anledning inte hann avslutas: låt det
        // aldrig hänga kvar och tysta stjäla nästa anrops resultat.
        continuation?.resume(returning: nil)
        continuation = nil

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            manager.requestLocation()

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate
    // Nonisolated + hopp till MainActor för varje callback — samma mönster
    // som `WatchService`s NSWorkspace-callback (se FORBATTRINGAR, Fas 2b):
    // CLLocationManagerDelegates krav är inte MainActor-isolerade i sig, men
    // allt tillståndet de rör (`authorizationStatus`, `continuation`) är det.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            guard let pending = self.continuation else { return }
            self.continuation = nil
            pending.resume(returning: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastError = message
            guard let pending = self.continuation else { return }
            self.continuation = nil
            pending.resume(returning: nil)
        }
    }
}
