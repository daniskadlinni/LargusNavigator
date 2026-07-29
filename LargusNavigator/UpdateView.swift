import SwiftUI
import AppKit

struct UpdateView: View {
    private let dataFolder = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("LargusNavigator", isDirectory: true)

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5"
    }

    var body: some View {
        Form {
            Section("Установленная версия") {
                LabeledContent("Largus Navigator", value: version)
                Text("Новые версии устанавливаются поверх старой. Данные автомобиля, ТО и расходов остаются отдельно и не удаляются.")
                    .foregroundStyle(.secondary)
            }

            Section("Как обновлять") {
                Text("Скачайте новый архив, распакуйте его и запустите файл «Установить или обновить Largus Navigator.command». Он сам соберёт новую версию и заменит приложение в папке «Программы».")
                Text("Перед первым запуском команды macOS может потребовать разрешить её в разделе «Конфиденциальность и безопасность».")
                    .foregroundStyle(.secondary)
            }

            Section("Данные и резервная копия") {
                LabeledContent("Папка данных", value: dataFolder.path)
                    .textSelection(.enabled)

                HStack {
                    Button("Открыть папку данных") {
                        try? FileManager.default.createDirectory(
                            at: dataFolder,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(dataFolder)
                    }

                    Button("Создать резервную копию") {
                        createBackup()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Обновление и данные")
    }

    private func createBackup() {
        let source = dataFolder.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let name = "LargusNavigator_backup_\(formatter.string(from: Date())).json"
        let destination = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(name)

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}
