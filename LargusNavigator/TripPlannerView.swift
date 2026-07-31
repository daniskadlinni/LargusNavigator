import SwiftUI
import AppKit

struct TripPlannerView: View {
    @Environment(AppStore.self) private var store

    @State private var start =
        "Москва, Байкальская улица, 17к1"
    @State private var finish = "Волгоград"
    @State private var departure = Date()
    @State private var distance = 1000.0
    @State private var exportedURL: URL?
    @State private var exportError: String?

    private var fuelLiters: Double {
        distance * store.vehicle.averageConsumption / 100
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Подготовить поездку")
                    .font(.largeTitle.bold())

                GroupBox {
                    VStack(spacing: 14) {
                        LabeledContent("Старт") {
                            TextField("Адрес старта", text: $start)
                                .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("Финиш") {
                            TextField("Адрес назначения", text: $finish)
                                .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("Выезд") {
                            DatePicker("", selection: $departure)
                                .labelsHidden()
                        }

                        LabeledContent("Расстояние") {
                            HStack {
                                Slider(
                                    value: $distance,
                                    in: 100...2000,
                                    step: 10
                                )
                                Text("\(Int(distance)) км")
                                    .monospacedDigit()
                                    .frame(width: 80)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label(
                        "Параметры",
                        systemImage: "slider.horizontal.3"
                    )
                }

                HStack(spacing: 16) {
                    MetricCard(
                        title: "Топливо",
                        value: String(format: "%.0f л", fuelLiters),
                        icon: "fuelpump.fill"
                    )
                    MetricCard(
                        title: "Время",
                        value: "13–15 ч",
                        icon: "clock.fill"
                    )
                    MetricCard(
                        title: "Маршрут",
                        value: "М-4",
                        icon: "road.lanes"
                    )
                }

                HStack {
                    Button {
                        exportRoadbook()
                    } label: {
                        Label(
                            "Создать Roadbook PDF",
                            systemImage: "doc.richtext.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if let exportedURL {
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [exportedURL]
                            )
                        }
                        .controlSize(.large)
                    }
                }

                if let exportError {
                    Text(exportError)
                        .foregroundStyle(.red)
                }
            }
            .padding(28)
        }
    }

    private func exportRoadbook() {
        do {
            exportedURL = try RoadbookExporter.export(
                start: start,
                finish: finish,
                departure: departure,
                distance: distance,
                consumption: store.vehicle.averageConsumption
            )
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}
