import SwiftUI
import MapKit

struct TravelPlannerView: View {
    @Environment(AppStore.self) private var store

    @State private var title = "Поездка на рыбалку"
    @State private var kind = "Рыбалка"
    @State private var start = "Москва, Байкальская улица, 17к1"
    @State private var finish = ""

    @State private var route1Name = "Основной"
    @State private var route2Name = "Через озеро / заезд"
    @State private var route3Name = "Альтернативная дорога"

    @State private var route1Waypoints = ""
    @State private var route2Waypoints = ""
    @State private var route3Waypoints = ""

    @State private var departure = Date()
    @State private var optimize = false
    @State private var fuelPrice = 62.0
    @State private var notes = ""
    @State private var checklist = TravelPlannerView.defaultChecklist
    @State private var plannedRoute: PlannedRoute?
    @State private var routeOptions: [PlannedRoute] = []
    @State private var selectedRouteIndex = 0
    @State private var fuelStations: [MKMapItem] = []
    @State private var weather: [WeatherSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let planner = RoutePlanningService()
    private let weatherService = WeatherService()

    private var fuelLiters: Double {
        (plannedRoute?.distanceKM ?? 0) * store.vehicle.averageConsumption / 100
    }

    private var fuelCost: Double { fuelLiters * fuelPrice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Путешествия и рыбалка").font(.largeTitle.bold())
                    Spacer()
                    Text("Маршрут: \(store.routingSettings.provider.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Поездка") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Название поездки", text: $title)
                        Picker("Тип", selection: $kind) {
                            Text("Рыбалка").tag("Рыбалка")
                            Text("Путешествие").tag("Путешествие")
                            Text("Семейная поездка").tag("Семейная поездка")
                        }

                        HStack {
                            TextField("Старт — общий для всех маршрутов", text: $start)
                            TextField("Финиш — общий для всех маршрутов", text: $finish)
                        }

                        DatePicker("Выезд", selection: $departure)

                        Toggle("Оптимизировать порядок точек внутри каждого маршрута", isOn: $optimize)
                        Text("Оставь выключенным, если специально задаёшь конкретную дорогу через свои точки.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            TextField("Цена топлива", value: $fuelPrice, format: .number.precision(.fractionLength(2)))
                            Text("₽/л").foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Три независимых варианта") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("У каждого варианта — свой список промежуточных точек. Можно сделать один маршрут напрямую, второй через озеро, третий через совсем другую дорогу.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        scenarioEditor(
                            number: 1,
                            color: .green,
                            name: $route1Name,
                            text: $route1Waypoints,
                            hint: "Например: Воронеж\\nБорисоглебск"
                        )

                        Divider()

                        scenarioEditor(
                            number: 2,
                            color: .red,
                            name: $route2Name,
                            text: $route2Waypoints,
                            hint: "Например: озеро / база / город для заезда"
                        )

                        Divider()

                        scenarioEditor(
                            number: 3,
                            color: .blue,
                            name: $route3Name,
                            text: $route3Waypoints,
                            hint: "Например: Тамбов\\nСаратов\\nКамышин"
                        )

                        Button {
                            Task { await buildThreeScenarios() }
                        } label: {
                            Label(isLoading ? "Считаю 3 маршрута…" : "Рассчитать и сравнить 3 маршрута",
                                  systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || finish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(8)
                }

                if let route = plannedRoute {
                    GroupBox("Сравнение маршрутов") {
                        HStack(spacing: 10) {
                            ForEach(Array(routeOptions.enumerated()), id: \.element.id) { index, option in
                                Button {
                                    selectRoute(index)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(routeColor(index))
                                                .frame(width: 10, height: 10)
                                            Text(routeName(option, index: index))
                                                .font(.headline)
                                                .lineLimit(1)
                                        }
                                        Text(String(format: "%.0f км", option.distanceKM))
                                        Text(durationText(option.duration))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        let delta = option.distanceKM - (routeOptions.first?.distanceKM ?? option.distanceKM)
                                        if index > 0 {
                                            Text(String(format: "%+.0f км к маршруту 1", delta))
                                                .font(.caption2)
                                                .foregroundStyle(delta > 0 ? Color.secondary : Color.green)
                                        }
                                    }
                                    .frame(minWidth: 150, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .tint(index == selectedRouteIndex ? routeColor(index) : .gray)
                            }
                            Spacer()
                        }
                        .padding(8)
                    }

                    RouteMapView()
                        .frame(minHeight: 720, idealHeight: 760)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 12) {
                        MetricCard(title: "Расстояние", value: String(format: "%.0f км", route.distanceKM), icon: "road.lanes")
                        MetricCard(title: "В пути", value: durationText(route.duration), icon: "clock.fill")
                        MetricCard(title: "Топливо", value: String(format: "%.1f л", fuelLiters), icon: "fuelpump.fill")
                        MetricCard(title: "Стоимость", value: String(format: "%.0f ₽", fuelCost), icon: "rublesign.circle.fill")
                    }

                    GroupBox("Точки выбранного маршрута") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(realAddresses(route).enumerated()), id: \.offset) { index, address in
                                Text("\(index + 1). \(address)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox("АЗС по выбранному маршруту") {
                        let routeFuelPOIs = store.currentPOIs.filter { $0.category == .fuel }

                        if routeFuelPOIs.isEmpty {
                            Text("Сетевые АЗС ещё не найдены")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Найдено сетевых АЗС: \(routeFuelPOIs.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(routeFuelPOIs) { station in
                                    HStack(spacing: 8) {
                                        Image(systemName: "fuelpump.fill")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(station.name)
                                            if let kilometer = station.roadKilometerLabel {
                                                Text(kilometer)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("км трассы: нет данных")
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        Spacer()
                                        if station.distanceFromRouteKM > 0.05 {
                                            Text(String(format: "%.1f км от трассы", station.distanceFromRouteKM))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }

                    GroupBox("Погода по пути и в финише") {
                        if weather.isEmpty {
                            Text("Погода ещё загружается").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 14) {
                                ForEach(weather, id: \.place) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.place).font(.headline)
                                        Text(item.description)
                                        Text(String(format: "%.0f °C · ветер %.0f км/ч", item.temperature, item.windSpeed))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }

                GroupBox("Обязательный чеклист") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($checklist) { $item in
                            Toggle(isOn: $item.isDone) {
                                HStack {
                                    Text(item.title)
                                    if item.isRequired {
                                        Text("обязательно").font(.caption2).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        HStack {
                            Button("Добавить пункт") {
                                checklist.append(ChecklistItem(title: "Новый пункт", category: "Своё", isRequired: false))
                            }
                            Spacer()
                            Text("Готово: \(checklist.filter(\.isDone).count)/\(checklist.count)")
                        }
                    }
                    .padding(8)
                }

                GroupBox("Заметки и покупки") {
                    TextEditor(text: $notes).frame(minHeight: 100)
                }

                Button {
                    saveTrip()
                } label: {
                    Label("Сохранить выбранный вариант поездки", systemImage: "square.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(plannedRoute == nil)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private func scenarioEditor(
        number: Int,
        color: Color,
        name: Binding<String>,
        text: Binding<String>,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 12, height: 12)
                Text("Маршрут \(number)").font(.headline)
                TextField("Название варианта", text: name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Промежуточные точки этого маршрута — по одной в строке")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(hint)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .frame(minHeight: 80)
                    .font(.body.monospaced())
            }

            HStack {
                Button("Очистить точки") {
                    text.wrappedValue = ""
                }
                .buttonStyle(.link)

                Spacer()

                if number > 1 {
                    Button("Скопировать точки маршрута 1") {
                        text.wrappedValue = route1Waypoints
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func buildThreeScenarios() async {
        isLoading = true
        errorMessage = nil

        let scenarios = [
            (name: cleanName(route1Name, fallback: "Основной"), waypoints: parseWaypoints(route1Waypoints)),
            (name: cleanName(route2Name, fallback: "Маршрут 2"), waypoints: parseWaypoints(route2Waypoints)),
            (name: cleanName(route3Name, fallback: "Маршрут 3"), waypoints: parseWaypoints(route3Waypoints))
        ]

        do {
            var calculated: [PlannedRoute] = []
            var errors: [String] = []

            for scenario in scenarios {
                do {
                    var settings = store.routingSettings
                    settings.alternativeCount = 1
                    settings.diverseCorridors = false

                    guard let route = try await planner.planAlternatives(
                        start: start,
                        waypoints: scenario.waypoints,
                        finish: finish,
                        optimize: optimize,
                        settings: settings,
                        departure: departure
                    ).first else {
                        throw RouteError.routeNotFound
                    }

                    calculated.append(named(route, scenario: scenario.name))
                } catch {
                    errors.append("\(scenario.name): \(error.localizedDescription)")
                }
            }

            guard !calculated.isEmpty else {
                throw RouteError.routeNotFound
            }

            routeOptions = calculated
            selectedRouteIndex = 0
            plannedRoute = calculated[0]
            store.currentRouteOptions = calculated
            store.selectedRouteIndex = 0

            await refreshSelectedRouteDetails(calculated[0])

            if !errors.isEmpty {
                errorMessage = "Не удалось рассчитать некоторые варианты:\n" + errors.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func selectRoute(_ index: Int) {
        guard routeOptions.indices.contains(index) else { return }
        selectedRouteIndex = index
        plannedRoute = routeOptions[index]
        store.selectedRouteIndex = index

        Task {
            await refreshSelectedRouteDetails(routeOptions[index])
        }
    }

    private func refreshSelectedRouteDetails(_ route: PlannedRoute) async {
        // OSM/Apple map POIs are loaded and cached by RouteMapView. The legacy
        // MKMapItem list is only consumed by the embedded Yandex map.
        let stations = route.provider == .yandex
            ? ((try? await planner.fuelStations(near: route)) ?? [])
            : []
        fuelStations = stations
        store.currentFuelStations = stations

        var result: [WeatherSummary] = []
        if let middle = route.mapItems.dropFirst().dropLast().first,
           let item = try? await weatherService.current(
            place: middle.name ?? "По пути",
            coordinate: middle.placemark.coordinate
           ) {
            result.append(item)
        }

        if let last = route.mapItems.last,
           let item = try? await weatherService.current(
            place: last.name ?? "Финиш",
            coordinate: last.placemark.coordinate
           ) {
            result.append(item)
        }
        weather = result
    }

    private func named(_ route: PlannedRoute, scenario: String) -> PlannedRoute {
        PlannedRoute(
            orderedAddresses: ["Сценарий: \(scenario)"] + route.orderedAddresses,
            mapItems: route.mapItems,
            routes: route.routes,
            pathCoordinates: route.pathCoordinates,
            distanceKM: route.distanceKM,
            duration: route.duration,
            alternativeIndex: route.alternativeIndex,
            provider: route.provider,
            hasTolls: route.hasTolls
        )
    }

    private func routeName(_ route: PlannedRoute, index: Int) -> String {
        if let marker = route.orderedAddresses.first, marker.hasPrefix("Сценарий: ") {
            return marker.replacingOccurrences(of: "Сценарий: ", with: "")
        }
        return "Маршрут \(index + 1)"
    }

    private func realAddresses(_ route: PlannedRoute) -> [String] {
        route.orderedAddresses.filter { !$0.hasPrefix("Сценарий: ") }
    }

    private func parseWaypoints(_ text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func selectedWaypoints() -> [String] {
        switch selectedRouteIndex {
        case 1: parseWaypoints(route2Waypoints)
        case 2: parseWaypoints(route3Waypoints)
        default: parseWaypoints(route1Waypoints)
        }
    }

    private func cleanName(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func saveTrip() {
        guard let route = plannedRoute else { return }
        var trip = SavedTrip()
        trip.title = title
        trip.kind = kind
        trip.start = start
        trip.waypoints = selectedWaypoints()
        trip.finish = finish
        trip.departure = departure
        trip.distanceKM = route.distanceKM
        trip.durationSeconds = route.duration
        trip.fuelLiters = fuelLiters
        trip.fuelCost = fuelCost
        trip.notes = notes
        trip.checklist = checklist
        store.saveTrip(trip)
    }

    private func routeColor(_ index: Int) -> Color {
        switch index % 3 {
        case 0: .green
        case 1: .red
        default: .blue
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours) ч \(minutes) мин"
    }

    static let defaultChecklist: [ChecklistItem] = [
        .init(title: "Документы, права, страховка", category: "Документы"),
        .init(title: "Телефон, зарядки, пауэрбанк", category: "Связь"),
        .init(title: "Аптечка и личные лекарства", category: "Безопасность"),
        .init(title: "Проверить масло, давление и омывайку", category: "Автомобиль"),
        .init(title: "Запас воды и еда в дорогу", category: "Питание"),
        .init(title: "Наличные и банковские карты", category: "Деньги"),
        .init(title: "Удилища, катушки, оснастка", category: "Рыбалка"),
        .init(title: "Подсачек, садок, инструменты", category: "Рыбалка"),
        .init(title: "Палатка, раскладушки, спальники", category: "Лагерь"),
        .init(title: "Фонари и запасные батарейки", category: "Лагерь"),
        .init(title: "Средства от солнца и насекомых", category: "Защита"),
        .init(title: "Проверить прогноз и уровень воды", category: "Подготовка")
    ]
}
