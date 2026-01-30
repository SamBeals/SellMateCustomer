import Foundation

struct PiVendClient {
    struct VendError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // IMPORTANT: your FastAPI is currently on port 8000.
    // If you later move it behind something else, update this.
    let baseURL: URL = URL(string: "http://192.168.0.134:8000")!
    let apiKey: String = "CHANGE_ME" // must match your FastAPI VEND_API_KEY header check

    // MARK: - NEW: mask-based vend sequence
    func sendVendSequence(request: PiVendSequenceRequest) async throws -> PiVendSequenceResponse {
        let url = baseURL.appendingPathComponent("vend_sequence")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let bodyData = try JSONEncoder().encode(request)
        req.httpBody = bodyData

        // DEBUG LOGGING — KEEP FOR NOW
        print("========== PI VEND_SEQUENCE REQUEST ==========")
        print("URL:", req.url?.absoluteString ?? "<nil>")
        print("METHOD:", req.httpMethod ?? "<nil>")
        print("HEADERS:")
        req.allHTTPHeaderFields?.forEach { key, value in
            print("  \(key): \(value)")
        }
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            print("BODY:")
            print(bodyString)
        } else {
            print("BODY: <non-utf8>")
        }
        print("=============================================")

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw VendError(message: "No HTTP response from Pi.")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("========== PI VEND_SEQUENCE RESPONSE ==========")
        print("STATUS:", http.statusCode)
        print("BODY:")
        print(responseBody)
        print("==============================================")

        guard (200...299).contains(http.statusCode) else {
            throw VendError(message: "Pi vend_sequence failed (\(http.statusCode)): \(responseBody)")
        }

        do {
            let decoded = try JSONDecoder().decode(PiVendSequenceResponse.self, from: data)
            return decoded
        } catch {
            throw VendError(message: "Failed to decode vend_sequence response: \(error.localizedDescription). Body: \(responseBody)")
        }
    }

    // MARK: - Legacy debug: mask-based single pulse (still useful)
    func testVend(mask: Int, pulseSeconds: Double = 2.0) async throws {
        let url = baseURL.appendingPathComponent("vend_mask")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let payload: [String: Any] = [
            "mask": mask,
            "pulse_seconds": pulseSeconds,
            "pulses": 1,
            "gap_seconds": 0.0
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        req.httpBody = bodyData

        // DEBUG LOGGING — KEEP FOR NOW
        print("========== PI VEND_MASK REQUEST ==========")
        print("URL:", req.url?.absoluteString ?? "<nil>")
        print("METHOD:", req.httpMethod ?? "<nil>")
        print("HEADERS:")
        req.allHTTPHeaderFields?.forEach { key, value in
            print("  \(key): \(value)")
        }
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            print("BODY:")
            print(bodyString)
        } else {
            print("BODY: <non-utf8>")
        }
        print("====================================")

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw VendError(message: "No HTTP response from Pi.")
        }

        if !(200...299).contains(http.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("========== PI VEND_MASK RESPONSE ==========")
            print("STATUS:", http.statusCode)
            print("BODY:")
            print(responseBody)
            print("====================================")
            throw VendError(message: "Pi vend_mask failed (\(http.statusCode)): \(responseBody)")
        }

        print("[PiVendClient] vend_mask succeeded (status \(http.statusCode))")
    }
}
