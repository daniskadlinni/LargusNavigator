import SwiftUI

struct MobileVehicleView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Автомобиль") {
                TextField("Название", text: $store.vehicle.name)
                TextField("Пробег", value: $store.vehicle.mileage, format: .number)
                TextField("Расход, л/100 км", value: $store.vehicle.averageConsumption, format: .number)
                TextField("Объём бака, л", value: $store.vehicle.tankCapacityLiters, format: .number)
            }
            Section("Заправки") {
                TextField("Минимальный остаток, л", value: $store.fuelPlanningSettings.minimumReserveLiters, format: .number)
                Toggle("Предпочитать АЗС справа", isOn: $store.fuelPlanningSettings.preferSameSide)
                NavigationLink("Любимые сети: \(store.fuelPlanningSettings.preferredNetworks.count)") {
                    List(FuelPlanningSettings.knownNetworks, id: \.self) { network in
                        Toggle(network, isOn: Binding(
                            get: { store.fuelPlanningSettings.preferredNetworks.contains(network) },
                            set: { enabled in
                                if enabled { store.fuelPlanningSettings.preferredNetworks.insert(network) }
                                else { store.fuelPlanningSettings.preferredNetworks.remove(network) }
                            }
                        ))
                    }
                    .navigationTitle("Любимые сети")
                }
            }
            Button("Сохранить") { store.save() }
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Автомобиль")
    }
}
