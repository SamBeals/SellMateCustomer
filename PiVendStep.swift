//
//  PiVendStep.swift
//  SellMateCustomer
//
//  Created by Sam on 1/28/26.
//


import Foundation

// MARK: - Pi Vend Sequence (NEW CONTRACT)
//
// Request:
// {
//   "order_id": "pi_...",
//   "steps": [
//     { "mask": 128, "pulses": 2, "pulse_seconds": 0.7, "gap_seconds": 0.3 }
//   ]
// }
//
// Response:
// {
//   "ok": true,
//   "mode": "vend_sequence",
//   "order_id": "pi_...",
//   "steps": [
//     { "mask": "0x80", "pulses": 2, "pulse_seconds": 0.7, "gap_seconds": 0.3 }
//   ]
// }

struct PiVendStep: Codable, Equatable {
    let mask: Int
    let pulses: Int
    let pulse_seconds: Double
    let gap_seconds: Double

    init(mask: Int, pulses: Int, pulseSeconds: Double, gapSeconds: Double) {
        self.mask = mask
        self.pulses = pulses
        self.pulse_seconds = pulseSeconds
        self.gap_seconds = gapSeconds
    }
}

struct PiVendSequenceRequest: Codable, Equatable {
    let order_id: String
    let steps: [PiVendStep]

    init(orderId: String, steps: [PiVendStep]) {
        self.order_id = orderId
        self.steps = steps
    }
}

struct PiVendStepEcho: Codable, Equatable {
    // Pi returns mask as hex string like "0x80"
    let mask: String
    let pulses: Int
    let pulse_seconds: Double
    let gap_seconds: Double
}

struct PiVendSequenceResponse: Codable, Equatable {
    let ok: Bool
    let mode: String
    let order_id: String?
    let steps: [PiVendStepEcho]?
}
