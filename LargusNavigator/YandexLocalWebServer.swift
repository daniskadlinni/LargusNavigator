import Foundation
import Network

final class YandexLocalWebServer: @unchecked Sendable {
    private final class StartState: @unchecked Sendable { var error: Error? }
    static let shared = YandexLocalWebServer()

    private let queue = DispatchQueue(label: "ru.denis.largusnavigator.yandex.localserver")
    private var listener: NWListener?
    private(set) var port: UInt16?

    private init() {}

    func start() throws -> UInt16 {
        if let port { return port }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)
        let stateBox = StartState()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    self?.port = p
                }
                semaphore.signal()
            case .failed(let error):
                stateBox.error = error
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        _ = semaphore.wait(timeout: .now() + 5)
        if let startError = stateBox.error { throw startError }
        guard let port else {
            throw NSError(domain: "LargusNavigator.LocalServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить локальный HTTP-сервер"])
        }
        return port
    }

    func url(path: String, apiKey: String) throws -> URL {
        let port = try start()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = path
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw NSError(domain: "LargusNavigator.LocalServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось сформировать локальный URL"])
        }
        return url
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.send("Bad Request", status: "400 Bad Request", on: connection)
                return
            }
            let target = String(parts[1])
            let url = URL(string: "http://localhost\(target)")
            let path = url?.path ?? "/"
            let key = URLComponents(url: url ?? URL(string: "http://localhost/")!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" })?.value ?? ""

            let html: String
            switch path {
            case "/engine": html = self.engineHTML(apiKey: key)
            case "/map": html = self.mapHTML(apiKey: key)
            default: html = "<html><body>Largus Navigator local server</body></html>"
            }
            self.send(html, on: connection)
        }
    }

    private func send(_ body: String, status: String = "200 OK", on connection: NWConnection) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func scriptURL(apiKey: String) -> String {
        var components = URLComponents(string: "https://api-maps.yandex.ru/2.1/")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "lang", value: "ru_RU"),
            URLQueryItem(name: "mode", value: "debug"),
            URLQueryItem(name: "onerror", value: "largusApiLoadError")
        ]
        return escaped(components.url?.absoluteString ?? "")
    }

    private func engineHTML(apiKey: String) -> String {
        let script = scriptURL(apiKey: apiKey)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <script>
        function largusDescribeError(e){try{if(!e)return 'неизвестная ошибка';if(typeof e==='string')return e;if(e.message)return String(e.message);if(e.error&&e.error.message)return String(e.error.message);if(e.name)return String(e.name);return JSON.stringify(e)}catch(_){return String(e)}}
        function largusPost(p){try{window.webkit.messageHandlers.largus.postMessage(p)}catch(_){}}
        function largusFail(stage,e,id){largusPost({type:'error',requestId:id||'',message:stage+': '+largusDescribeError(e)})}
        function largusApiLoadError(e){largusFail('Загрузка Yandex JS API',e,'')}
        (function(){var oldError=console.error;console.error=function(){try{largusFail('Console',Array.prototype.map.call(arguments,largusDescribeError).join(' | '),'')}catch(_){};if(oldError)oldError.apply(console,arguments)}})();
        </script>
        <script src="\(script)"></script>
        <style>html,body,#map{width:24px;height:24px;margin:0;overflow:hidden}</style></head><body><div id="map"></div>
        <script>
        function post(p){largusPost(p)}
        function fail(m,id){post({type:'error',requestId:id||'',message:String(m||'Ошибка Yandex JS API')})}
        var largusReadyTimer=setTimeout(function(){if(typeof ymaps==='undefined'){fail('Загрузка Yandex JS API: объект ymaps не появился. Проверь ключ, пакет API и Referer localhost.','')}},15000);
        if(typeof ymaps!=='undefined'){
          ymaps.ready(function(){clearTimeout(largusReadyTimer);try{window.hiddenMap=new ymaps.Map('map',{center:[55.75,37.62],zoom:5,controls:[]});post({type:'ready'})}catch(e){largusFail('Инициализация карты',e,'')}},
                      function(e){clearTimeout(largusReadyTimer);largusFail('Инициализация Yandex JS API',e,'')});
        }

        window.largusCalculateRoute=function(id,addresses,useTraffic,results){
          var timeout=setTimeout(function(){fail('Маршрутизация: таймаут 30 секунд',id)},30000)
          try{
            var mr=new ymaps.multiRouter.MultiRoute({referencePoints:addresses,params:{routingMode:'auto',avoidTrafficJams:!!useTraffic,results:Math.max(1,Math.min(3,Number(results)||1))}},{boundsAutoApply:false})
            hiddenMap.geoObjects.removeAll(); hiddenMap.geoObjects.add(mr)
            mr.model.events.add('requestfail',function(ev){clearTimeout(timeout);var er=ev&&ev.get?ev.get('error'):null;largusFail('Маршрутизация',er||'requestfail',id)})
            mr.model.events.add('requestsuccess',function(){clearTimeout(timeout);try{
              var out=[]; mr.getRoutes().each(function(route){
                var d=route.properties.get('distance'),dt=route.properties.get('durationInTraffic')||route.properties.get('duration'),paths=[]
                route.getPaths().each(function(path){var pc=[];path.getSegments().each(function(seg){try{var sc=seg.geometry.getCoordinates();if(Array.isArray(sc))sc.forEach(function(p){if(Array.isArray(p)&&p.length>=2)pc.push([Number(p[0]),Number(p[1])])})}catch(_){}});if(pc.length>1)paths.push(pc)})
                out.push({distanceMeters:d&&d.value?Number(d.value):0,durationSeconds:dt&&dt.value?Number(dt.value):0,paths:paths})
              }); if(!out.length){fail('Маршрутизация: маршрут построен без вариантов',id);return} post({type:'routes',requestId:id,routes:out})
            }catch(e){largusFail('Обработка маршрута',e,id)}})
          }catch(e){clearTimeout(timeout);largusFail('Маршрутизация',e,id)}
        }
        </script></body></html>
        """
    }

    private func mapHTML(apiKey: String) -> String {
        let script = scriptURL(apiKey: apiKey)
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <script>
        function largusDescribeError(e){try{if(!e)return 'неизвестная ошибка';if(typeof e==='string')return e;if(e.message)return String(e.message);if(e.error&&e.error.message)return String(e.error.message);if(e.name)return String(e.name);return JSON.stringify(e)}catch(_){return String(e)}}
        function showError(t){var m=document.getElementById('map');if(m)m.innerHTML='<div class="error">'+String(t)+'</div>'}
        function largusApiLoadError(e){showError('Загрузка Yandex JS API: '+largusDescribeError(e))}
        </script>
        <script src="\(script)"></script>
        <style>html,body,#map{width:100%;height:100%;margin:0;background:#eef2f5}.error{font:15px -apple-system;padding:24px;white-space:pre-wrap}</style></head><body><div id="map"></div>
        <script>
        var largusMap=null;
        var largusReadyTimer=setTimeout(function(){if(typeof ymaps==='undefined')showError('Yandex JS API не загрузился. Проверь ключ, пакет API и Referer localhost.')},15000);
        if(typeof ymaps!=='undefined')ymaps.ready(function(){clearTimeout(largusReadyTimer);try{largusMap=new ymaps.Map('map',{center:[55.75,37.62],zoom:5,controls:['zoomControl','typeSelector','fullscreenControl']});window.webkit.messageHandlers.largusMap.postMessage({type:'ready'})}catch(e){showError('Инициализация карты: '+largusDescribeError(e))}},function(e){clearTimeout(largusReadyTimer);showError('Инициализация Yandex JS API: '+largusDescribeError(e))});
        window.renderLargusMap=function(routes,points,stations,selected){if(!largusMap)return;largusMap.geoObjects.removeAll();var bp=[];
          routes.forEach(function(r,ri){r.forEach(function(path){if(!path||path.length<2)return;path.forEach(function(p){bp.push(p)});largusMap.geoObjects.add(new ymaps.Polyline(path,{}, {strokeColor:ri===selected?'#5B3FD1':'#8A8A8A',strokeWidth:ri===selected?6:3,strokeOpacity:ri===selected?0.95:0.45}))})});
          points.forEach(function(p,i){var pr=i===0?'islands#greenAutoIcon':(i===points.length-1?'islands#redFlagIcon':'islands#blueCircleDotIcon');largusMap.geoObjects.add(new ymaps.Placemark([p.lat,p.lon],{iconCaption:p.name,balloonContent:p.name},{preset:pr}));bp.push([p.lat,p.lon])});
          stations.forEach(function(s){largusMap.geoObjects.add(new ymaps.Placemark([s.lat,s.lon],{iconCaption:s.name,balloonContent:s.name},{preset:'islands#orangeCircleDotIcon'}))});
          if(bp.length>1){largusMap.setBounds(ymaps.util.bounds.fromPoints(bp),{checkZoomRange:true,zoomMargin:40})}}
        </script></body></html>
        """
    }

}
