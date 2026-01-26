//
//  CartLine.swift
//  SellMateTrial
//
//  Created by Sam on 1/25/26.
//

import Foundation
import Combine

struct CartLine: Identifiable, Equatable {
    var id: String { slotId }     // unique per slot for MVP
    let slotId: String            // "S01" etc
    let name: String
    let priceCents: Int
    let quantityAvailable: Int    // from Firestore merged inventory
    let motorId: String
    let i2cMask: Int?             // optional for later (vend_mask)
    var qty: Int
}

@MainActor
final class OrderDraft: ObservableObject {
    @Published private(set) var linesBySlot: [String: CartLine] = [:]

    func add(slot: Slot) {
        // Only allow adding if it’s sellable
        guard slot.enabled else { return }
        guard slot.inventory > 0 else { return }
        guard let product = slot.product else { return }
        let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if var existing = linesBySlot[slot.slotId] {
            // Don’t exceed available inventory
            if existing.qty < existing.quantityAvailable {
                existing.qty += 1
                linesBySlot[slot.slotId] = existing
            }
            return
        }

        let line = CartLine(
            slotId: slot.slotId,
            name: name,
            priceCents: product.priceCents,
            quantityAvailable: slot.inventory,
            motorId: slot.motor.motorId,
            i2cMask: slot.i2c?.mask,
            qty: 1
        )
        linesBySlot[slot.slotId] = line
    }

    func increment(slotId: String) {
        guard var existing = linesBySlot[slotId] else { return }
        if existing.qty < existing.quantityAvailable {
            existing.qty += 1
            linesBySlot[slotId] = existing
        }
    }

    func removeOne(slotId: String) {
        guard var existing = linesBySlot[slotId] else { return }
        existing.qty -= 1
        if existing.qty <= 0 {
            linesBySlot.removeValue(forKey: slotId)
        } else {
            linesBySlot[slotId] = existing
        }
    }

    func clear() {
        linesBySlot.removeAll()
    }

    var lines: [CartLine] {
        Array(linesBySlot.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var itemCount: Int {
        lines.reduce(0) { $0 + $1.qty }
    }

    var totalCents: Int {
        lines.reduce(0) { $0 + ($1.priceCents * $1.qty) }
    }
}

func formatUSD(cents: Int) -> String {
    let dollars = Double(cents) / 100.0
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: dollars)) ?? "$\(String(format: "%.2f", dollars))"
}

