//
//  CheckoutView.swift
//  SellMateTrial
//
//  Created by Sam on 1/25/26.
//

import SwiftUI
import Combine
import StripeTerminal

struct CheckoutView: View {
    @ObservedObject var order: OrderDraft
    @Environment(\.dismiss) private var dismiss

    private var connectedReader: Reader? {
        guard Terminal.isInitialized() else { return nil }
        return Terminal.shared.connectedReader
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                // Reader status section
                Section(header: Text("Reader")) {
                    if let reader = connectedReader {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deviceTypeName(reader.deviceType))
                                    .font(.headline)
                                Text("SN: \(reader.serialNumber)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let locationId = reader.locationId, !locationId.isEmpty {
                                Text(locationId)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("No reader connected.")
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Order")) {
                    if order.lines.isEmpty {
                        Text("Your cart is empty.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(order.lines) { line in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(line.name)
                                        .font(.headline)
                                    Text("Slot \(line.slotId)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 6) {
                                    Text("\(line.qty) × \(formatUSD(cents: line.priceCents))")
                                        .font(.caption)

                                    HStack(spacing: 8) {
                                        Button("−") { order.removeOne(slotId: line.slotId) }
                                            .buttonStyle(.bordered)
                                        Button("+") {
                                            order.increment(slotId: line.slotId)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(line.qty >= line.quantityAvailable)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Total")) {
                    HStack {
                        Text("Total")
                        Spacer()
                        Text(formatUSD(cents: order.totalCents))
                            .bold()
                    }
                }
            }

            // Bottom action bar
            HStack {
                Button("Back") { dismiss() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Finish Purchase") {
                    Task { @MainActor in
                        guard Terminal.isInitialized(), Terminal.shared.connectedReader != nil else {
                            print("[Checkout] No reader connected")
                            return
                        }

                        // Collect vending masks from cart lines
                        let masks = order.lines.compactMap { $0.i2cMask }

                        // Trigger the end-to-end payment + vend flow
                        let result = await TerminalSessionManager.shared.processPurchase(
                            amountCents: order.totalCents,
                            currency: "usd",
                            masks: masks,
                            pulseSeconds: 2.0
                        )

                        switch result {
                        case .success:
                            order.clear()
                            dismiss()
                        case .failure(let error):
                            print("[Checkout] Purchase failed: \(error.localizedDescription)")
                            // Optionally surface TerminalSessionManager.shared.errorText in UI
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(order.lines.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Checkout")
    }
}

// Local helper for readable device names
private func deviceTypeName(_ type: DeviceType) -> String {
    switch type {
    case .chipper2X: return "Chipper 2X"
    case .wisePad3: return "WisePad 3"
    case .stripeM2: return "Stripe Reader M2"
    case .wisePosE: return "WisePOS E"
    case .wisePosEDevKit: return "WisePOS E DevKit"
    case .etna: return "Etna"
    case .chipper1X: return "Chipper 1X"
    case .wiseCube: return "WiseCube"
    case .stripeS700: return "Stripe Reader S700"
    case .stripeS700DevKit: return "Stripe Reader S700 DevKit"
    case .stripeS710: return "Stripe Reader S710"
    case .stripeS710DevKit: return "Stripe Reader S710 DevKit"
    case .verifoneV660p: return "Verifone V660p"
    case .verifoneV660pDevKit: return "Verifone V660p DevKit"
    case .verifoneM425: return "Verifone M425"
    case .verifoneM450: return "Verifone M450"
    case .verifoneP630: return "Verifone P630"
    case .verifoneUX700: return "Verifone UX700"
    case .verifoneUX700DevKit: return "Verifone UX700 DevKit"
    case .verifoneVM100: return "Verifone VM100"
    case .verifoneVP100: return "Verifone VP100"
    case .tapToPay: return "Tap To Pay"
    case .stripeT600: return "Stripe Reader T600"
    case .stripeT600DevKit: return "Stripe Reader T600 DevKit"
    @unknown default: return "Unknown Reader"
    }
}
