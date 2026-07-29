import SwiftUI
@preconcurrency import WebKit
import MapKit

struct YandexEmbeddedMapView: NSViewRepresentable {
    let options: [PlannedRoute]
    let selectedIndex: Int
    let apiKey: String
    let fuelStations: [MKMapItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "largusMap")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.payload = makePayload()
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        do {
            let url = try YandexLocalWebServer.shared.url(path: "/map", apiKey: cleaned)
            if context.coordinator.loadedKey != cleaned || webView.url?.host != "localhost" {
                context.coordinator.loadedKey = cleaned
                context.coordinator.isReady = false
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("http://localhost/", forHTTPHeaderField: "Referer")
                webView.load(request)
            } else if context.coordinator.isReady {
                context.coordinator.render()
            }
        } catch {
            context.coordinator.payload = nil
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "largusMap")
    }

    private func makePayload() -> String {
        let routeArrays: [[[[Double]]]] = options.map { route in
            route.pathCoordinates.map { path in path.map { [$0.latitude, $0.longitude] } }
        }
        let points: [[String: Any]] = (options.indices.contains(selectedIndex) ? options[selectedIndex].mapItems : []).enumerated().map { index, item in
            [
                "lat": item.placemark.coordinate.latitude,
                "lon": item.placemark.coordinate.longitude,
                "name": index == 0 ? "Старт" : (index == (options.indices.contains(selectedIndex) ? options[selectedIndex].mapItems.count - 1 : -1) ? "Финиш" : (item.name ?? "Точка"))
            ]
        }
        let stations: [[String: Any]] = fuelStations.map { item in
            ["lat": item.placemark.coordinate.latitude, "lon": item.placemark.coordinate.longitude, "name": item.name ?? "АЗС"]
        }
        let object: [String: Any] = ["routes": routeArrays, "points": points, "stations": stations, "selected": selectedIndex]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKScriptMessageHandler {
        weak var webView: WKWebView?
        var loadedKey = ""
        var isReady = false
        var payload: String?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "largusMap", let body = message.body as? [String: Any], body["type"] as? String == "ready" else { return }
            isReady = true
            render()
        }

        func render() {
            guard isReady, let payload else { return }
            webView?.evaluateJavaScript("(function(){var p=\(payload);window.renderLargusMap(p.routes,p.points,p.stations,p.selected);})();")
        }
    }
}
