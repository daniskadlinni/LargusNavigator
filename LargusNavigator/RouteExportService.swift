import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum RouteExportService {
    @MainActor
    static func exportGPX(route: PlannedRoute, stops: [RecommendedFuelStop]) throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = "LargusNavigator-route.gpx"
        guard panel.runModal() == .OK, let url = panel.url else { throw CocoaError(.userCancelled) }

        let track = route.coordinates.map {
            "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"></trkpt>"
        }.joined(separator: "\n")
        let waypoints = stops.map {
            "<wpt lat=\"\($0.station.latitude)\" lon=\"\($0.station.longitude)\"><name>\(xml($0.station.name))</name></wpt>"
        }.joined(separator: "\n")
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Largus Navigator" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypoints)
        <trk><name>Largus Navigator</name><trkseg>\(track)</trkseg></trk>
        </gpx>
        """
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    static func exportPDF(route: PlannedRoute, stops: [RecommendedFuelStop]) throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "LargusNavigator-roadbook.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { throw CocoaError(.userCancelled) }

        let image = NSImage(size: NSSize(width: 595, height: 842))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 595, height: 842).fill()
        let title = "Largus Navigator — Roadbook"
        title.draw(at: NSPoint(x: 40, y: 790), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black
        ])
        String(format: "Маршрут: %.0f км · %@", route.distanceKM, duration(route.duration))
            .draw(at: NSPoint(x: 40, y: 752), withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
        var y: CGFloat = 710
        if stops.isEmpty {
            "Рекомендуемые заправки не требуются или не найдены."
                .draw(at: NSPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        } else {
            for (index, stop) in stops.prefix(12).enumerated() {
                let km = stop.station.roadKilometerLabel
                    ?? String(format: "%.0f км маршрута", stop.station.routeProgressKM ?? 0)
                "\(index + 1). \(stop.station.name) — \(km) — \(stop.station.routeSide.title)"
                    .draw(at: NSPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
                y -= 34
            }
        }
        image.unlockFocus()

        let document = PDFDocument()
        guard let page = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
        document.insert(page, at: 0)
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @MainActor
    static func copyMapLink(route: PlannedRoute) -> Bool {
        guard let first = route.coordinates.first, let last = route.coordinates.last else { return false }
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "saddr", value: "\(first.latitude),\(first.longitude)"),
            URLQueryItem(name: "daddr", value: "\(last.latitude),\(last.longitude)"),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        guard let text = components.url?.absoluteString else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 3600) ч \((Int(seconds) % 3600) / 60) мин"
    }
}
