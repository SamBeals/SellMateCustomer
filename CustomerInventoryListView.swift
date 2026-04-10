import SwiftUI
import Combine

private func dollars(_ cents: Int) -> String {
    String(format: "$%.2f", Double(cents) / 100.0)
}

struct CustomerInventoryListView: View {
    @StateObject private var vm: CustomerInventoryViewModel
    @StateObject private var order = OrderDraft()
    @ObservedObject private var terminal = TerminalSessionManager.shared
    @State private var showCheckout = false

    private let machineName: String

    init(machineId: String = "machine_001", machineName: String = "Available Items") {
        _vm = StateObject(wrappedValue: CustomerInventoryViewModel(machineId: machineId))
        self.machineName = machineName
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if vm.isLoading {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if let err = vm.errorText {
                        VStack(spacing: 8) {
                            Text("Error")
                                .font(.headline)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                            Button("Retry") { vm.load() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.slots.isEmpty {
                        VStack(spacing: 8) {
                            Text("No items available.")
                                .foregroundColor(.secondary)
                            Button("Reload") { vm.load() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(vm.slots) { slot in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(slot.product?.name.isEmpty == false ? slot.product!.name : "Empty")
                                        .font(.headline)
                                    Text(dollars(slot.product?.priceCents ?? 0))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Add to cart") {
                                    order.add(slot: slot)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!(slot.enabled && slot.inventory > 0 && (slot.product?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)))
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }

                if !order.lines.isEmpty {
                    Button {
                        showCheckout = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cart.fill")
                            Text(dollars(order.totalCents))
                                .bold()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 2)
                    }
                    .padding()
                }
            }
            .navigationTitle(machineName)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        // Retrigger discovery/connection if not connected yet.
                        terminal.ensureConnected(simulated: false)
                    } label: {
                        HStack(spacing: 6) {
                            if terminal.isBusy {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            let status = terminal.connectedReader != nil ? "Connected" : "Connect Reader"
                            Text("Reader: \(status)")
                                .font(.caption)
                                .foregroundColor(terminal.connectedReader != nil ? .green : .secondary)
                        }
                    }
                    .disabled(terminal.isBusy) // Optional: prevent spamming while busy
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") { vm.load() }
                }
            }
            .onAppear {
                if vm.slots.isEmpty && vm.isLoading == false {
                    vm.load()
                }
                terminal.ensureConnected(simulated: false)
            }
            .sheet(isPresented: $showCheckout) {
                NavigationStack {
                    CheckoutView(order: order)
                }
            }
        }
    }
}

#Preview {
    CustomerInventoryListView()
}
