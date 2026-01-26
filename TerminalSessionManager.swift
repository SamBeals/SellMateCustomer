import Foundation
import SwiftUI
import Combine
import StripeTerminal

@MainActor
final class TerminalSessionManager: NSObject, ObservableObject {
    static let shared = TerminalSessionManager()

    @Published private(set) var connectedReader: Reader?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var errorText: String?

    // New: publish discovered readers so UI can present a list
    @Published private(set) var discoveredReaders: [Reader] = []

    private var discoveryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    // Reuse your existing backend token endpoint and default location
    private let tokenURL = URL(string: "http://192.168.0.134:4242/connection_token")!
    private let defaultLocationId: String = "tml_GWCmogANWkpxV7" // live location id

    private override init() {
        super.init()
    }

    private func configureIfNeeded() {
        if !Terminal.isInitialized() {
            // Reuse the BackendTokenProvider you already defined elsewhere in the project
            let provider = BackendTokenProvider(tokenURL: tokenURL)
            Terminal.initWithTokenProvider(
                provider,
                delegate: self,
                offlineDelegate: nil,
                logLevel: LogLevel.verbose
            )
            Terminal.shared.delegate = self
            statusMessage = "Terminal configured."
            print("[TerminalSession] Terminal configured (initialized).")
        } else {
            Terminal.shared.delegate = self
            print("[TerminalSession] Terminal already initialized. Delegate set.")
        }
    }

    // Convenience: auto-discover and auto-connect to the first reader found (for kiosk-like flows)
    func ensureConnected(simulated: Bool = false) {
        configureIfNeeded()

        // Already connected
        if let existing = Terminal.shared.connectedReader {
            connectedReader = existing
            statusMessage = "Connected to \(existing.serialNumber)."
            print("[TerminalSession] Already connected to \(existing.serialNumber).")
            return
        }

        // Avoid overlapping runs
        guard discoveryTask == nil, connectionTask == nil else {
            print("[TerminalSession] Discovery/connection already in progress. Skipping ensureConnected.")
            return
        }

        isBusy = true
        statusMessage = simulated ? "Discovering simulated readers..." : "Discovering readers..."
        errorText = nil
        print("[TerminalSession] Starting discovery (simulated=\(simulated)) for auto-connect.")

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try BluetoothScanDiscoveryConfigurationBuilder()
                    .setSimulated(simulated)
                    .build()

                // Take the first batch that yields any reader and connect to the first one.
                var chosen: Reader?
                for try await readers in Terminal.shared.discoverReaders(config) {
                    print("[TerminalSession] [Auto] Discovery update: \(readers.count) reader(s) found.")
                    if let first = readers.first {
                        print("[TerminalSession] [Auto] Choosing first reader: \(first.serialNumber) (type=\(first.deviceType.rawValue), locationId=\(first.locationId ?? "<none>"))")
                        chosen = first
                        break
                    }
                }

                if let reader = chosen {
                    await MainActor.run {
                        self.statusMessage = "Connecting to \(reader.serialNumber)..."
                    }
                    try await self.connect(to: reader)
                } else {
                    await MainActor.run {
                        self.statusMessage = "No readers found."
                        self.isBusy = false
                    }
                    print("[TerminalSession] [Auto] No readers found during discovery.")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = "Discovery canceled."
                    self.isBusy = false
                }
                print("[TerminalSession] [Auto] Discovery canceled.")
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.statusMessage = "Discovery failed."
                    self.isBusy = false
                }
                print("[TerminalSession] [Auto] Discovery failed: \(error.localizedDescription)")
            }
            await MainActor.run { self.discoveryTask = nil }
        }
    }

    // New: manual discovery that updates discoveredReaders for UI selection
    func startDiscovery(simulated: Bool) {
        configureIfNeeded()

        // Reset previous results
        discoveredReaders = []
        errorText = nil

        guard discoveryTask == nil else {
            print("[TerminalSession] startDiscovery called while discovery is already running.")
            return
        }

        isBusy = true
        statusMessage = simulated ? "Discovering simulated readers..." : "Discovering readers..."
        print("[TerminalSession] Starting discovery (manual, simulated=\(simulated)).")

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try BluetoothScanDiscoveryConfigurationBuilder()
                    .setSimulated(simulated)
                    .build()

                for try await readers in Terminal.shared.discoverReaders(config) {
                    await MainActor.run {
                        self.discoveredReaders = readers
                        self.statusMessage = readers.isEmpty ? "Scanning… (no readers yet)" : "Found \(readers.count) reader(s)"
                    }
                    print("[TerminalSession] Discovery update: \(readers.count) reader(s). First: \(readers.first?.serialNumber ?? "<none>")")
                }

                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = "Discovery finished."
                }
                print("[TerminalSession] Discovery finished.")
            } catch is CancellationError {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = "Discovery canceled."
                }
                print("[TerminalSession] Discovery canceled.")
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.errorText = error.localizedDescription
                    self.statusMessage = "Discovery failed."
                }
                print("[TerminalSession] Discovery failed: \(error.localizedDescription)")
            }
            await MainActor.run { self.discoveryTask = nil }
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        print("[TerminalSession] cancelDiscovery() invoked.")
    }

    func connect(to reader: Reader) async throws {
        print("[TerminalSession] Connect requested to reader \(reader.serialNumber).")
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let locationIdToUse: String
                if let loc = reader.locationId, !loc.isEmpty {
                    locationIdToUse = loc
                } else if !self.defaultLocationId.isEmpty {
                    locationIdToUse = self.defaultLocationId
                } else {
                    throw NSError(domain: "Terminal", code: -1001, userInfo: [NSLocalizedDescriptionKey: "No Location ID available for connection."])
                }
                print("[TerminalSession] Using locationId \(locationIdToUse) for connection.")

                let config = try BluetoothConnectionConfigurationBuilder(
                    delegate: self,
                    locationId: locationIdToUse
                )
                .setAutoReconnectOnUnexpectedDisconnect(true)
                .build()

                print("[TerminalSession] Calling connectReader...")
                let connected = try await Terminal.shared.connectReader(reader, connectionConfig: config)
                await MainActor.run {
                    self.connectedReader = connected
                    self.statusMessage = "Connected to \(connected.serialNumber)."
                    self.isBusy = false
                    self.discoveredReaders = [] // clear list once connected
                }
                print("[TerminalSession] Connected to \(connected.serialNumber) (type=\(connected.deviceType.rawValue)).")
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = "Connection canceled."
                    self.isBusy = false
                }
                print("[TerminalSession] Connection canceled.")
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.statusMessage = "Connect failed."
                    self.isBusy = false
                }
                print("[TerminalSession] Connect failed: \(error.localizedDescription)")
            }
            await MainActor.run { self.connectionTask = nil }
        }
        _ = try? await connectionTask?.value
    }

    func disconnect() {
        guard Terminal.shared.connectedReader != nil else {
            print("[TerminalSession] disconnect() called but no reader is connected.")
            return
        }
        isBusy = true
        statusMessage = "Disconnecting..."
        print("[TerminalSession] Disconnecting reader...")
        Task { @MainActor in
            do {
                try await Terminal.shared.disconnectReader()
                self.connectedReader = nil
                self.statusMessage = "Disconnected."
                print("[TerminalSession] Disconnected.")
            } catch {
                self.errorText = error.localizedDescription
                self.statusMessage = "Disconnect failed."
                print("[TerminalSession] Disconnect failed: \(error.localizedDescription)")
            }
            self.isBusy = false
        }
    }

    // MARK: - Purchase flow (Finish Purchase) using two-step collect + confirm with detailed logs
    func processPurchase(amountCents: Int, currency: String = "usd", masks: [Int], pulseSeconds: Double = 2.0) async -> Result<PaymentIntent, Error> {
        configureIfNeeded()

        guard amountCents > 0 else {
            let err = NSError(domain: "TerminalSession", code: -2000, userInfo: [NSLocalizedDescriptionKey: "Amount must be greater than 0"])
            self.errorText = err.localizedDescription
            return .failure(err)
        }
        guard Terminal.shared.connectedReader != nil else {
            let err = NSError(domain: "TerminalSession", code: -2001, userInfo: [NSLocalizedDescriptionKey: "No reader connected"])
            self.errorText = err.localizedDescription
            return .failure(err)
        }

        isBusy = true
        statusMessage = "Creating PaymentIntent..."
        errorText = nil

        do {
            // 1) Build PaymentIntent parameters
            var builder = PaymentIntentParametersBuilder(
                amount: UInt(amountCents),
                currency: currency
            )
            // If your old flow used automatic capture, uncomment:
            // builder = builder.setCaptureMethod(.automatic)

            let params = try builder.build()

            print("[TerminalSession] Creating PaymentIntent for \(amountCents) \(currency)")
            let intent = try await Terminal.shared.createPaymentIntent(params)
            print("[TerminalSession] Created PI: \(intent.stripeId) status=\(intent.status.rawValue)")

            // 2) Collect payment method on reader
            statusMessage = "Present card..."
            print("[TerminalSession] Collecting payment method for PI \(intent.stripeId) ...")
            let collected = try await Terminal.shared.collectPaymentMethod(intent)
            print("[TerminalSession] Collected payment method. PI status=\(collected.status.rawValue)")

            // 3) Confirm the PaymentIntent
            statusMessage = "Processing payment..."
            print("[TerminalSession] Confirming PI \(collected.stripeId) ...")
            let processed = try await Terminal.shared.confirmPaymentIntent(collected)
            print("[TerminalSession] Confirmed PI \(processed.stripeId) status=\(processed.status.rawValue)")

            // 4) Vend after success (if any masks supplied)
            if !masks.isEmpty {
                let combinedMask = masks.reduce(0, |)
                print("[TerminalSession] Payment success; vending with mask \(combinedMask) pulse=\(pulseSeconds)")
                let vendClient = PiVendClient()
                do {
                    try await vendClient.testVend(mask: combinedMask, pulseSeconds: pulseSeconds)
                    print("[TerminalSession] Vend call completed.")
                } catch {
                    // Payment already succeeded; surface vend error but do not fail the payment result
                    print("[TerminalSession] Vend error after payment success: \(error.localizedDescription)")
                }
            } else {
                print("[TerminalSession] Payment succeeded; no vending masks provided.")
            }

            statusMessage = "Payment succeeded"
            isBusy = false
            return .success(processed)
        } catch {
            self.errorText = error.localizedDescription
            self.statusMessage = "Payment failed"
            self.isBusy = false
            print("[TerminalSession] Purchase failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

extension TerminalSessionManager: TerminalDelegate {
    func terminal(_ terminal: Terminal, didChangeConnectionStatus status: ConnectionStatus) {
        // Reflect status changes
        let text: String
        switch status {
        case .notConnected: text = "Reader not connected"
        case .connecting: text = "Reader connecting…"
        case .connected: text = "Reader connected"
        @unknown default: text = "Reader status unknown"
        }
        statusMessage = text
        print("[TerminalSession] TerminalDelegate didChangeConnectionStatus: \(status.rawValue) -> \(text)")
    }

    func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {
        Task { @MainActor in
            self.connectedReader = nil
            self.statusMessage = "Reader unexpectedly disconnected."
            print("[TerminalSession] Unexpected reader disconnect: \(reader.serialNumber)")
        }
    }
}

extension TerminalSessionManager: ReaderDelegate, MobileReaderDelegate {
    func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {
        print("[TerminalSession] Reader available update: \(update)")
    }
    func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
        print("[TerminalSession] Reader started installing update.")
    }
    func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        print("[TerminalSession] Reader update progress: \(progress)")
    }
    func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
        print("[TerminalSession] Reader finished update. error=\(String(describing: error))")
    }
    func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {
        print("[TerminalSession] Reader requested input: \(inputOptions)")
    }
    func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        print("[TerminalSession] Reader display message: \(displayMessage)")
    }

    // MobileReaderDelegate
    func reader(_ reader: Reader, didStartReconnect cancelable: Cancelable?) {
        print("[TerminalSession] Reader auto-reconnect started.")
        statusMessage = "Reconnecting to reader…"
    }
    func reader(_ reader: Reader, didFinishReconnect result: Result<Void, Error>) {
        switch result {
        case .success:
            print("[TerminalSession] Reader auto-reconnect succeeded.")
            statusMessage = "Reader reconnected."
        case .failure(let error):
            print("[TerminalSession] Reader auto-reconnect failed: \(error.localizedDescription)")
            statusMessage = "Reader reconnect failed."
        }
    }
}
