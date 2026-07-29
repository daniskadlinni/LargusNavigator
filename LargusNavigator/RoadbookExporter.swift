import AppKit
import PDFKit
import UniformTypeIdentifiers

enum RoadbookExporter {
    @MainActor
    static func export(
        start: String,
        finish: String,
        departure: Date,
        distance: Double,
        consumption: Double
    ) throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Roadbook.pdf"

        guard panel.runModal() == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }

        let image = makePage(
            start: start,
            finish: finish,
            departure: departure,
            distance: distance,
            consumption: consumption
        )

        let document = PDFDocument()
        guard let page = PDFPage(image: image) else {
            throw CocoaError(.fileWriteUnknown)
        }
        document.insert(page, at: 0)

        guard document.write(to: url) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return url
    }

    private static func makePage(
        start: String,
        finish: String,
        departure: Date,
        distance: Double,
        consumption: Double
    ) -> NSImage {
        let size = NSSize(width: 595, height: 842)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(
            rect: NSRect(origin: .zero, size: size)
        ).fill()

        draw(
            "LARGUS NAVIGATOR",
            x: 42,
            y: 770,
            size: 28,
            weight: .heavy,
            color: .white
        )
        draw(
            "ROADBOOK",
            x: 42,
            y: 735,
            size: 17,
            weight: .bold,
            color: .systemBlue
        )

        draw(
            start,
            x: 42,
            y: 670,
            size: 17,
            weight: .semibold,
            color: .white
        )
        draw(
            "↓",
            x: 48,
            y: 625,
            size: 24,
            weight: .bold,
            color: .systemBlue
        )
        draw(
            finish,
            x: 42,
            y: 580,
            size: 24,
            weight: .heavy,
            color: .white
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"

        let fuel = distance * consumption / 100
        let rows = [
            ("Выезд", formatter.string(from: departure)),
            ("Расстояние", "\(Int(distance)) км"),
            (
                "Средний расход",
                String(format: "%.1f л/100 км", consumption)
            ),
            ("Расчёт топлива", String(format: "%.0f л", fuel)),
            (
                "Маршрут",
                "М-4 → Воронеж → Анна → Борисоглебск"
            ),
            ("Топливо", "АИ-95")
        ]

        var y: CGFloat = 510

        for (label, value) in rows {
            NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: 38,
                    y: y - 12,
                    width: 519,
                    height: 48
                ),
                xRadius: 12,
                yRadius: 12
            ).fill()

            draw(
                label,
                x: 55,
                y: y + 7,
                size: 12,
                weight: .medium,
                color: .lightGray
            )
            draw(
                value,
                x: 220,
                y: y + 5,
                size: 14,
                weight: .semibold,
                color: .white
            )

            y -= 60
        }

        draw(
            "ЧЕК-ЛИСТ",
            x: 42,
            y: 125,
            size: 16,
            weight: .bold,
            color: .systemBlue
        )
        draw(
            "Масло • антифриз • давление • документы • " +
            "компрессор • трос",
            x: 42,
            y: 93,
            size: 12,
            weight: .regular,
            color: .white
        )

        return image
    }

    private static func draw(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: size,
                weight: weight
            ),
            .foregroundColor: color
        ]

        text.draw(
            at: NSPoint(x: x, y: y),
            withAttributes: attributes
        )
    }
}
