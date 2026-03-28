//
//  CheckoutView.swift
//  SellMateTrial
//
//  Created by Sam on 1/25/26.
//  Updated by Sam on 1/27/26.
//

import SwiftUI

struct CheckoutView: View {
    @ObservedObject var order: OrderDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(header: Text("Terminal Payment")) {
                    Text("This flow triggers payment/vending through the cloud backend, matching the Android kiosk app.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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

                                        Button("+") { order.increment(slotId: line.slotId) }
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

            HStack {
                Button("Back") { dismiss() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Finish Purchase") {
                    Task { @MainActor in
                        let result = await TerminalSessionManager.shared.processPurchaseViaCloud(
                            amountCents: order.totalCents,
                            lines: order.lines
                        )

                        switch result {
                        case .success(let finalStatus):
                            print("[Checkout] Cloud checkout complete: order_id=\(finalStatus.order_id), status=\(finalStatus.status)")
                            order.clear()
                            dismiss()

                        case .failure(let error):
                            print("[Checkout] Cloud checkout failed: \(error.localizedDescription)")
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
