import SwiftUI
import MapKit
import CoreLocation

struct LandingView: View {
    @StateObject private var vm = LandingMapViewModel()
    @State private var selectedMachine: MachineLocation?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition) {
                    UserAnnotation()

                    ForEach(vm.nearbyMachines) { machine in
                        Annotation(machine.name, coordinate: machine.coordinate) {
                            Button {
                                selectedMachine = machine
                            } label: {
                                Circle()
                                    .fill(selectedMachine?.id == machine.id ? Color.accentColor : Color.red)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .ignoresSafeArea(edges: .bottom)

                if let selectedMachine {
                    machineCard(selectedMachine)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if vm.isLoading {
                    ProgressView("Loading nearby machines…")
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Nearby Machines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload") { vm.loadMachines() }
                }
            }
            .overlay(alignment: .top) {
                if vm.authorizationStatus == .denied || vm.authorizationStatus == .restricted {
                    Text("Location permission is off. Showing all machines we can find.")
                        .font(.caption)
                        .padding(10)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 10)
                }
            }
            .alert("Could not load machines", isPresented: Binding(
                get: { vm.errorText != nil },
                set: { if !$0 { vm.errorText = nil } }
            )) {
                Button("Retry") { vm.loadMachines() }
                Button("Dismiss", role: .cancel) { vm.errorText = nil }
            } message: {
                Text(vm.errorText ?? "Unknown error")
            }
            .task {
                vm.requestLocationAccessIfNeeded()
                vm.loadMachines()
            }
            .onChange(of: vm.userLocation) { _, newLocation in
                guard let location = newLocation else { return }
                withAnimation {
                    cameraPosition = .region(
                        MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func machineCard(_ machine: MachineLocation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(machine.name)
                .font(.headline)

            Text(machine.id)
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink {
                CustomerInventoryListView(machineId: machine.id, machineName: machine.name)
            } label: {
                Text("View Inventory")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

#Preview {
    LandingView()
}
