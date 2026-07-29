import Foundation
import CoreLocation
@preconcurrency import WebKit

struct YandexJSRouteOption {
    let distanceMeters: Double
    let durationSeconds: Double
    let coordinates: [[CLLocationCoordinate2D]]
}

@MainActor
final class YandexJSRouteEngine: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {
    static let shared = YandexJSRouteEngine()

    private var webView: WKWebView?
    private var configuredKey = ""
    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingRoutes: [String: CheckedContinuation<[YandexJSRouteOption], Error>] = [:]

    private override init() { super.init() }

    func calculate(addresses: [String], useTraffic: Bool, requestedResults: Int, apiKey: String) async throws -> [YandexJSRouteOption] {
        guard addresses.count >= 2 else { throw RouteError.routeNotFound }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RouteError.yandexKeyMissing }
        try await ensureReady(apiKey: key)

        let requestID = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: addresses)
        guard let addressesJSON = String(data: data, encoding: .utf8) else { throw RouteError.invalidRequest }
        let resultCount = addresses.count > 2 ? 1 : min(3, max(1, requestedResults))
        let script = "window.largusCalculateRoute(\"\(requestID)\", \(addressesJSON), \(useTraffic ? "true" : "false"), \(resultCount));"

        return try await withCheckedThrowingContinuation { continuation in
            pendingRoutes[requestID] = continuation
            webView?.evaluateJavaScript(script)
        }
    }

    func reset() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "largus")
        webView = nil
        configuredKey = ""
        isReady = false
        let error = RouteError.yandexResponse("Яндекс JavaScript API был перезапущен")
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        pendingRoutes.values.forEach { $0.resume(throwing: error) }
        pendingRoutes.removeAll()
    }

    private func ensureReady(apiKey: String) async throws {
        if configuredKey != apiKey || webView == nil { try setupWebView(apiKey: apiKey) }
        if isReady { return }
        try await withCheckedThrowingContinuation { continuation in readyWaiters.append(continuation) }
    }

    private func setupWebView(apiKey: String) throws {
        reset()
        configuredKey = apiKey

        let controller = WKUserContentController()
        controller.add(self, name: "largus")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let url = try YandexLocalWebServer.shared.url(path: "/engine", apiKey: apiKey)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        // Yandex explicitly warns that WebView containers may send an incorrect Referer.
        // Force the same Referer that is whitelisted in the Developer Dashboard.
        request.setValue("http://localhost/", forHTTPHeaderField: "Referer")
        view.load(request)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "largus", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case "error":
            let requestID = body["requestId"] as? String ?? ""
            let text = body["message"] as? String ?? "Ошибка Яндекс JavaScript API"
            let error = RouteError.yandexResponse(text)
            if let c = pendingRoutes.removeValue(forKey: requestID) { c.resume(throwing: error); return }
            if !isReady {
                let waiters = readyWaiters
                readyWaiters.removeAll()
                waiters.forEach { $0.resume(throwing: error) }
            }
        case "routes":
            guard let requestID = body["requestId"] as? String,
                  let continuation = pendingRoutes.removeValue(forKey: requestID),
                  let rawRoutes = body["routes"] as? [[String: Any]] else { return }
            let routes = rawRoutes.compactMap { raw -> YandexJSRouteOption? in
                guard let distance = raw["distanceMeters"] as? NSNumber,
                      let duration = raw["durationSeconds"] as? NSNumber else { return nil }
                let rawPaths = raw["paths"] as? [[[Any]]] ?? []
                let paths = rawPaths.map { path in
                    path.compactMap { point -> CLLocationCoordinate2D? in
                        guard point.count >= 2,
                              let lat = (point[0] as? NSNumber)?.doubleValue,
                              let lon = (point[1] as? NSNumber)?.doubleValue else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                }.filter { $0.count >= 2 }
                return YandexJSRouteOption(distanceMeters: distance.doubleValue, durationSeconds: duration.doubleValue, coordinates: paths)
            }
            routes.isEmpty ? continuation.resume(throwing: RouteError.routeNotFound) : continuation.resume(returning: routes)
        default: break
        }
    }
}
