import Foundation
import FirebaseFirestore
import CoreLocation

struct MachineLocation: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    var location: CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

enum MachineLocatorError: LocalizedError {
    case missingGeoPoint

    var errorDescription: String? {
        switch self {
        case .missingGeoPoint:
            return "Machine is missing a valid GeoPoint."
        }
    }
}

final class MachineLocatorService {
    private let db: Firestore
    private let machinesCollection = "machines"

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func loadMachines() async throws -> [MachineLocation] {
        let snapshot = try await db.collection(machinesCollection).getDocuments()

        return snapshot.documents.compactMap { doc in
            try? decodeMachine(documentId: doc.documentID, data: doc.data())
        }
    }

    private func decodeMachine(documentId: String, data: [String: Any]) throws -> MachineLocation {
        let machineName = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (machineName?.isEmpty == false) ? machineName! : "Machine \(documentId)"

        if let gp = data["geoPoint"] as? GeoPoint
            ?? data["geopoint"] as? GeoPoint
            ?? data["location"] as? GeoPoint {
            return MachineLocation(
                id: documentId,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: gp.latitude, longitude: gp.longitude)
            )
        }

        if let locationMap = data["location"] as? [String: Any],
           let latitude = coerceDouble(locationMap["latitude"] ?? locationMap["lat"]),
           let longitude = coerceDouble(locationMap["longitude"] ?? locationMap["lng"] ?? locationMap["lon"] ?? locationMap["long"]) {
            return MachineLocation(
                id: documentId,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }

        throw MachineLocatorError.missingGeoPoint
    }

    private func coerceDouble(_ any: Any?) -> Double? {
        switch any {
        case let d as Double:
            return d
        case let i as Int:
            return Double(i)
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
