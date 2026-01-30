//
//  VendSequenceItem.swift
//  SellMateCustomer
//
//  Created by Sam on 1/27/26.
//


//
//  VendSequenceModels.swift
//  SellMateTrial
//
//  Created by Sam on 1/27/26.
//

import Foundation

struct VendSequenceItem: Codable, Equatable {
    let slot_id: String
    let qty: Int

    init(slotId: String, qty: Int) {
        self.slot_id = slotId
        self.qty = qty
    }
}

struct VendSequenceRequest: Codable, Equatable {
    let order_id: String
    let items: [VendSequenceItem]
    let pulse_ms: Int
    let settle_ms: Int

    init(orderId: String, items: [VendSequenceItem], pulseMs: Int = 900, settleMs: Int = 500) {
        self.order_id = orderId
        self.items = items
        self.pulse_ms = pulseMs
        self.settle_ms = settleMs
    }
}

struct VendStepResult: Codable, Equatable {
    let slot_id: String
    let ok: Bool
    let error: String?
}

struct VendSequenceResponse: Codable, Equatable {
    let status: String           // "ok" | "busy" | "error"
    let order_id: String?
    let message: String?
    let results: [VendStepResult]?
}
