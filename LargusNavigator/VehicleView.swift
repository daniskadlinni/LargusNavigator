import SwiftUI

struct VehicleView: View {
    @Environment(AppStore.self) private var store
    @State private var savedMessage = ""

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Автомобиль") {
                TextField("Название", text: $store.vehicle.name)
                TextField("Госномер", text: $store.vehicle.plate)
                TextField("VIN", text: $store.vehicle.vin)
                TextField("Двигатель", text: $store.vehicle.engine)
                Stepper("Год: \(store.vehicle.year)", value: $store.vehicle.year, in: 2000...2035)
                Stepper("Мощность: \(store.vehicle.powerHP) л.с.", value: $store.vehicle.powerHP, in: 50...300)
                Stepper("Мест: \(store.vehicle.seats)", value: $store.vehicle.seats, in: 2...9)
            }

            Section("Эксплуатация") {
                TextField("Топливо", text: $store.vehicle.fuel)
                TextField("Пробег", value: $store.vehicle.mileage, format: .number)
                TextField("Средний расход", value: $store.vehicle.averageConsumption, format: .number)
                TextField("Объём бака, л", value: $store.vehicle.tankCapacityLiters, format: .number)
            }

            Section("Планирование заправок") {
                TextField("Минимальный остаток в баке, л", value: $store.fuelPlanningSettings.minimumReserveLiters, format: .number)
                Slider(value: $store.fuelPlanningSettings.startFuelPercent, in: 10...100, step: 5) {
                    Text("Топливо на старте")
                } minimumValueLabel: {
                    Text("10%")
                } maximumValueLabel: {
                    Text("100%")
                }
                Text("На старте: \(Int(store.fuelPlanningSettings.startFuelPercent))% бака")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Предпочитать АЗС справа по ходу движения", isOn: $store.fuelPlanningSettings.preferSameSide)

                DisclosureGroup("Любимые сети (\(store.fuelPlanningSettings.preferredNetworks.count))") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading) {
                        ForEach(FuelPlanningSettings.knownNetworks, id: \.self) { network in
                            Toggle(network, isOn: Binding(
                                get: { store.fuelPlanningSettings.preferredNetworks.contains(network) },
                                set: { enabled in
                                    if enabled {
                                        store.fuelPlanningSettings.preferredNetworks.insert(network)
                                    } else {
                                        store.fuelPlanningSettings.preferredNetworks.remove(network)
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            HStack {
                Button("Сохранить") {
                    store.save()
                    savedMessage = "Сохранено"
                }
                .buttonStyle(.borderedProminent)

                Text(savedMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Автомобиль")
    }
}
