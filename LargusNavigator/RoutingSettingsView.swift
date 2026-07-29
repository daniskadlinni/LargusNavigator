import SwiftUI

struct RoutingSettingsView: View {
    @Environment(AppStore.self) private var store

    @State private var apiKey = KeychainStore.yandexAPIKey()
    @State private var statusText = ""
    @State private var isTesting = false

    private let planner = RoutePlanningService()

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Основной движок") {
                Picker("Провайдер", selection: $store.routingSettings.provider) {
                    ForEach(RoutingProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .onChange(of: store.routingSettings.provider) { _, _ in store.save() }

                Text("OpenStreetMap даёт карту и дорожные данные, OSRM строит и сравнивает маршруты. Apple Maps остаётся резервом. Яндекс оставлен только для экспериментов.")
                    .foregroundStyle(.secondary)
            }

            Section("OpenStreetMap + OSRM") {
                Toggle("Строить 3 существенно разных коридора", isOn: $store.routingSettings.diverseCorridors)
                    .onChange(of: store.routingSettings.diverseCorridors) { _, _ in store.save() }

                Picker("Количество вариантов", selection: $store.routingSettings.alternativeCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .onChange(of: store.routingSettings.alternativeCount) { _, _ in store.save() }

                TextField("OSRM сервер", text: $store.routingSettings.osrmBaseURL)
                    .onSubmit { store.save() }

                VStack(alignment: .leading, spacing: 5) {
                    Text("По умолчанию используется публичный тестовый сервер router.project-osrm.org.")
                    Text("Для постоянного интенсивного использования позже можно указать свой или коммерческий OSRM-сервер без изменения приложения.")
                    Text("При режиме трёх коридоров приложение сначала использует нативные альтернативы OSRM, а недостающие варианты строит через разные автоматически подобранные опорные точки.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Резервный Apple Maps") {
                Text("Можно выбрать Apple Maps в списке провайдеров. API-ключ не нужен.")
                    .foregroundStyle(.secondary)
            }

            Section("Яндекс — экспериментально") {
                SecureField("API-ключ", text: $apiKey)
                    .textContentType(.password)
                HStack {
                    Button("Сохранить в Keychain") { saveKey() }
                    Button(isTesting ? "Проверяю…" : "Проверить") { Task { await testKey() } }
                        .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !statusText.isEmpty {
                    Text(statusText).foregroundStyle(statusText.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Маршрутизация")
    }

    private func saveKey() {
        do {
            try KeychainStore.saveYandexAPIKey(apiKey)
            YandexJSRouteEngine.shared.reset()
            statusText = "✓ Ключ сохранён"
        } catch { statusText = "✗ \(error.localizedDescription)" }
    }

    private func testKey() async {
        isTesting = true
        defer { isTesting = false }
        do {
            try KeychainStore.saveYandexAPIKey(apiKey)
            YandexJSRouteEngine.shared.reset()
            statusText = "✓ \(try await planner.testYandexKey(apiKey))"
        } catch { statusText = "✗ \(error.localizedDescription)" }
    }
}
