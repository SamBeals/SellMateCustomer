//
//  CustomerInventoryViewModel.swift
//  SellMateTrial
//
//  Created by Sam on 1/25/26.
//

import Foundation
import Combine

@MainActor
final class CustomerInventoryViewModel: ObservableObject {
    @Published var slots: [Slot] = []
    @Published var isLoading: Bool = false
    @Published var errorText: String?

    private let machineId: String
    private let service: FirestorePlanogramService

    init(machineId: String = "machine_001",
         service: FirestorePlanogramService = FirestorePlanogramService()) {
        self.machineId = machineId
        self.service = service
    }

    func load() {
        Task {
            isLoading = true
            errorText = nil
            defer { isLoading = false }

            do {
                let planogram = try await service.load(machineId: machineId)

                // “Inventory list” is basically “sellable slots”
                let sellable = planogram.allSlots.filter { slot in
                    guard slot.enabled else { return false }
                    guard slot.inventory > 0 else { return false }
                    guard let product = slot.product else { return false }
                    return !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                // Sort by name for now
                self.slots = sellable.sorted {
                    ($0.product?.name ?? "").localizedCaseInsensitiveCompare($1.product?.name ?? "") == .orderedAscending
                }
            } catch {
                self.errorText = error.localizedDescription
            }
        }
    }
}

