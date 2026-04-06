import Foundation
import StripeTerminal
import Combine

@MainActor
final class TerminalSessionManager: NSObject, ObservableObject {

    static let shared = TerminalSessionManager()

    @Published var isBusy: Bool = false
    @Published var errorText: String?

    var connectedReader: Reader? {
        guard Terminal.isInitialized() else { return nil }
        return Terminal.shared.connectedReader
    }

    private let pi = PiVendClient()

    // Backend endpoints (Pi-hosted Node server in your setup)
    private let tokenURL = URL(string: "http://192.168.0.134:4242/connection_token")!
    private let createPaymentIntentURL = URL(string: "http://192.168.0.134:4242/create_payment_intent")!
    private let cloudBackendBaseURL = URL(string: "https://sellmatebackend-472755926166.us-central1.run.app")!
    private let defaultMachineId = "machine_001"

    private let defaultLocationId: String = "tml_GV9bCglOApaios" // replace with your valid Location ID

    private override init() {
        super.init()
    }

    // MARK: - Existing API (legacy) — kept to avoid breaking callers
    func processPurchase(
        amountCents: Int,
        currency: String,
        masks: [Int],
        pulseSeconds: Double
    ) async -> Result<Void, Error> {
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            let paymentIntentId = try await performStripePayment(amountCents: amountCents, currency: currency)
            print("[TerminalSessionManager] Legacy processPurchase called; masks=\(masks); PaymentIntent=\(paymentIntentId)")
            return .success(())
        } catch {
            self.errorText = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - NEW API: vend via /vend_sequence using mask steps
    func processPurchase(
        amountCents: Int,
        currency: String,
        lines: [CartLine],
        pulseMs: Int = 900,
        settleMs: Int = 500
    ) async -> Result<PiVendSequenceResponse, Error> {

        guard !lines.isEmpty else {
            return .failure(NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cart is empty."]))
        }

        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            // 1) Take payment (Stripe Terminal)
            let paymentIntentId = try await performStripePayment(amountCents: amountCents, currency: currency)

            // 2) Build vend steps from cart lines
            let pulseSeconds = Double(pulseMs) / 1000.0
            let gapSeconds = Double(settleMs) / 1000.0

            var steps: [PiVendStep] = []

            for line in lines {
                guard line.qty > 0 else { continue }

                guard let mask = line.i2cMask else {
                    throw NSError(
                        domain: "SellMate",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Missing i2c mask for slot \(line.slotId). Cannot vend yet."]
                    )
                }

                steps.append(
                    PiVendStep(
                        mask: mask,
                        pulses: line.qty,
                        pulseSeconds: pulseSeconds,
                        gapSeconds: gapSeconds
                    )
                )
            }

            guard !steps.isEmpty else {
                throw NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "No vendable items found."])
            }

            let req = PiVendSequenceRequest(orderId: paymentIntentId, steps: steps)

            // 3) Call Pi
            let resp = try await pi.sendVendSequence(request: req)

            guard resp.ok == true else {
                let msg = "Vend failed (ok=false). mode=\(resp.mode) order_id=\(resp.order_id ?? "nil")"
                throw NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            return .success(resp)
        } catch {
            self.errorText = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Cloud checkout API (matches SellMateKioskApp Kotlin flow)
    func processPurchaseViaCloud(
        amountCents: Int,
        lines: [CartLine],
        machineId: String? = nil
    ) async -> Result<OrderStatusResponse, Error> {
        guard !lines.isEmpty else {
            return .failure(NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cart is empty."]))
        }

        isBusy = true
        errorText = nil
        defer { isBusy = false }

        do {
            let orderId = try await createCloudOrder(
                amountCents: amountCents,
                lines: lines,
                machineId: machineId ?? defaultMachineId
            )

            _ = try await startCloudPayment(orderId: orderId)
            let finalStatus = try await pollCloudOrder(orderId: orderId)
            return .success(finalStatus)
        } catch {
            self.errorText = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Reader connection
    func ensureConnected(simulated: Bool) {
        Task { @MainActor in
            do {
                try await initializeTerminalIfNeeded()

                if Terminal.shared.connectedReader != nil {
                    return
                }

                isBusy = true
                errorText = nil
                defer { isBusy = false }

                let discoveryBuilder = BluetoothScanDiscoveryConfigurationBuilder()
                    .setSimulated(simulated)
                let discoveryConfig = try discoveryBuilder.build()

                var firstDiscovered: Reader?

                for try await readers in Terminal.shared.discoverReaders(discoveryConfig) {
                    if let r = readers.first {
                        firstDiscovered = r
                        break
                    }
                }

                guard let reader = firstDiscovered else {
                    throw NSError(domain: "Terminal", code: -100, userInfo: [NSLocalizedDescriptionKey: "No readers discovered."])
                }

                let locationIdToUse: String
                if let loc = reader.locationId, !loc.isEmpty {
                    locationIdToUse = loc
                } else {
                    guard !defaultLocationId.isEmpty else {
                        throw NSError(domain: "Terminal", code: -101, userInfo: [NSLocalizedDescriptionKey: "Missing Location ID."])
                    }
                    locationIdToUse = defaultLocationId
                }

                let connBuilder = BluetoothConnectionConfigurationBuilder(
                    delegate: self,
                    locationId: locationIdToUse
                )
                .setAutoReconnectOnUnexpectedDisconnect(true)

                let connectionConfig = try connBuilder.build()

                let connected = try await Terminal.shared.connectReader(reader, connectionConfig: connectionConfig)
                print("[TerminalSessionManager] Connected to \(connected.serialNumber)")
            } catch {
                self.errorText = error.localizedDescription
                print("[TerminalSessionManager] ensureConnected error: \(error.localizedDescription)")
            }
        }
    }

    private func initializeTerminalIfNeeded() async throws {
        if !Terminal.isInitialized() {
            let provider = BackendTokenProvider(tokenURL: tokenURL)
            Terminal.initWithTokenProvider(
                provider,
                delegate: self,
                offlineDelegate: nil,
                logLevel: LogLevel.verbose
            )
        } else {
            Terminal.shared.delegate = self
        }
    }

    // MARK: - Stripe payment
    private func performStripePayment(amountCents: Int, currency: String) async throws -> String {
        try await initializeTerminalIfNeeded()

        let clientSecret = try await createPaymentIntentClientSecret(amountCents: amountCents, currency: currency)
        let retrieved = try await Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret)
        let collected = try await Terminal.shared.collectPaymentMethod(retrieved)
        let confirmed = try await Terminal.shared.confirmPaymentIntent(collected)

        guard let piId = confirmed.stripeId, !piId.isEmpty else {
            throw NSError(
                domain: "SellMate",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Stripe Terminal returned a nil or empty PaymentIntent id."]
            )
        }

        return piId
    }

    // MARK: - Backend create_payment_intent

    private struct CreatePaymentIntentRequest: Codable {
        let amount: Int
        let currency: String
    }

    private struct CreatePaymentIntentResponse: Codable {
        let paymentIntent: String
    }

    private func createPaymentIntentClientSecret(amountCents: Int, currency: String) async throws -> String {
        var req = URLRequest(url: createPaymentIntentURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = CreatePaymentIntentRequest(amount: amountCents, currency: currency)
        req.httpBody = try JSONEncoder().encode(payload)

        if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
            print("========== BACKEND create_payment_intent REQUEST ==========")
            print("URL:", createPaymentIntentURL.absoluteString)
            print("BODY:", s)
            print("===========================================================")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from backend."])
        }

        let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("========== BACKEND create_payment_intent RESPONSE ==========")
        print("STATUS:", http.statusCode)
        print("BODY:", bodyStr)
        print("===========================================================")

        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "SellMate",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Backend create_payment_intent failed (\(http.statusCode)): \(bodyStr)"]
            )
        }

        do {
            let decoded = try JSONDecoder().decode(CreatePaymentIntentResponse.self, from: data)
            return decoded.paymentIntent
        } catch {
            throw NSError(
                domain: "SellMate",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode backend create_payment_intent response: \(error.localizedDescription). Body: \(bodyStr)"]
            )
        }
    }

    // MARK: - Cloud Backend DTOs
    struct VendSequenceItem: Codable {
        let slot_id: String
        let qty: Int
    }

    struct CreateOrderRequest: Codable {
        let machine_id: String
        let items: [VendSequenceItem]
        let amount_cents: Int
    }

    struct CreateOrderResponse: Codable {
        let order_id: String
        let status: String
        let machine_id: String?
        let amount_cents: Int?
    }

    struct StartPaymentResponse: Codable {
        let order_id: String?
        let status: String
        let payment_intent_id: String?
    }

    struct OrderStatusResponse: Codable {
        let order_id: String
        let status: String
        let payment_intent_id: String?
        let amount_cents: Int?
    }

    private enum CheckoutState {
        static let success: Set<String> = ["completed", "vend_succeeded", "paid"]
        static let waiting: Set<String> = [
            "created",
            "payment_requested",
            "payment_pending",
            "processing",
            "authorized",
            "paid_pending_vend",
            "vending"
        ]
        static let failed: Set<String> = [
            "payment_failed",
            "vend_failed",
            "canceled",
            "cancelled",
            "failed",
            "error"
        ]
    }

    private func createCloudOrder(amountCents: Int, lines: [CartLine], machineId: String) async throws -> String {
        let items = lines
            .filter { $0.qty > 0 }
            .map { VendSequenceItem(slot_id: $0.slotId, qty: $0.qty) }

        guard !items.isEmpty else {
            throw NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "No vendable items found."])
        }

        let payload = CreateOrderRequest(machine_id: machineId, items: items, amount_cents: amountCents)
        let response: CreateOrderResponse = try await sendCloudRequest(
            path: "orders",
            method: "POST",
            body: payload
        )
        return response.order_id
    }

    private func startCloudPayment(orderId: String) async throws -> StartPaymentResponse {
        try await sendCloudRequest(
            path: "orders/\(orderId)/start_payment",
            method: "POST",
            body: Optional<String>.none
        ) as StartPaymentResponse
    }

    private func fetchCloudOrder(orderId: String) async throws -> OrderStatusResponse {
        try await sendCloudRequest(path: "orders/\(orderId)", method: "GET", body: Optional<String>.none) as OrderStatusResponse
    }

    private func pollCloudOrder(orderId: String, maxAttempts: Int = 60, intervalNs: UInt64 = 2_000_000_000) async throws -> OrderStatusResponse {
        for attempt in 1...maxAttempts {
            let current = try await fetchCloudOrder(orderId: orderId)
            let normalized = current.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if CheckoutState.success.contains(normalized) {
                return current
            }

            if CheckoutState.failed.contains(normalized) {
                throw NSError(
                    domain: "SellMate",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Order \(current.order_id) failed with status '\(current.status)'."]
                )
            }

            if !CheckoutState.waiting.contains(normalized) {
                print("[TerminalSessionManager] Unknown cloud status '\(current.status)' (attempt \(attempt)); continuing to poll.")
            }

            try await Task.sleep(nanoseconds: intervalNs)
        }

        throw NSError(
            domain: "SellMate",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for cloud checkout to finish for order \(orderId)."]
        )
    }

    private func sendCloudRequest<Response: Decodable, RequestBody: Encodable>(
        path: String,
        method: String,
        body: RequestBody?
    ) async throws -> Response {
        let url = cloudBackendBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            if let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) {
                print("[CloudCheckout] \(method) \(url.absoluteString) body=\(bodyString)")
            }
        } else {
            print("[CloudCheckout] \(method) \(url.absoluteString)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SellMate", code: 0, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from cloud backend."])
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("[CloudCheckout] status=\(http.statusCode), response=\(responseBody)")

        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "SellMate",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Cloud backend request failed (\(http.statusCode)): \(responseBody)"]
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NSError(
                domain: "SellMate",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode cloud backend response: \(error.localizedDescription). Body: \(responseBody)"]
            )
        }
    }
}

// MARK: - Delegates (minimal)
extension TerminalSessionManager: TerminalDelegate {
    func terminal(_ terminal: Terminal, didChangeConnectionStatus status: ConnectionStatus) {}
    func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {}
}

extension TerminalSessionManager: DiscoveryDelegate {
    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {}
}

extension TerminalSessionManager: ReaderDelegate, MobileReaderDelegate {
    func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {}
    func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {}
    func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}
    func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}
    func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {}
    func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}

    func reader(_ reader: Reader, didStartReconnect cancelable: Cancelable?) {}
    func reader(_ reader: Reader, didFinishReconnect result: Result<Void, Error>) {}
}
