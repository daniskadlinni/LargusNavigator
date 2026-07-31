import SwiftUI
import MapKit
import AppKit

/// Native macOS map renderer.
/// Basemap: Apple MapKit.
/// Routing geometry and trip logic remain OSM/OSRM.
struct OpenStreetMapView: NSViewRepresentable {
    let options: [PlannedRoute]
    let selectedIndex: Int
    let pois: [RoutePOI]
    let recommendedFuelIDs: Set<String>
    let fuelGaps: [FuelCoverageGap]
    let showFuel: Bool
    let showHotels: Bool
    let showFood: Bool
    let showGroceries: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsZoomControls = true
        mapView.showsScale = true
        mapView.showsBuildings = true

        context.coordinator.mapView = mapView
        refreshRoutes(on: mapView, coordinator: context.coordinator, fit: true)
        refreshPOIs(on: mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let rSig = routeSignature
        let pSig = poiSignature

        if rSig != context.coordinator.routeSignature {
            refreshRoutes(on: mapView, coordinator: context.coordinator, fit: true)
        }

        if pSig != context.coordinator.poiSignature {
            refreshPOIs(on: mapView, coordinator: context.coordinator)
        }
    }

    private var routeSignature: String {
        options.map { "\($0.id.uuidString):\($0.coordinates.count)" }
            .joined(separator: "|") + "#\(selectedIndex)#" + fuelGaps.map(\.id).joined(separator: "|")
    }

    private var visiblePOIs: [RoutePOI] {
        pois.filter {
            switch $0.category {
            case .fuel: showFuel
            case .hotel: showHotels
            case .food: showFood
            case .grocery: showGroceries
            }
        }
    }

    private var poiSignature: String {
        "\(showFuel)-\(showHotels)-\(showFood)-\(showGroceries)#" +
        visiblePOIs.map(\.id).sorted().joined(separator: "|")
        + "#" + recommendedFuelIDs.sorted().joined(separator: "|")
    }

    private func refreshRoutes(
        on mapView: MKMapView,
        coordinator: Coordinator,
        fit: Bool
    ) {
        let old = mapView.overlays.compactMap { $0 as? LargusRoutePolyline }
        mapView.removeOverlays(old)
        mapView.removeOverlays(mapView.overlays.compactMap { $0 as? FuelGapPolyline })

        let endpoints = mapView.annotations.compactMap { $0 as? RouteEndpointAnnotation }
        mapView.removeAnnotations(endpoints)

        var selectedRect = MKMapRect.null

        for (index, route) in options.enumerated() {
            let coords = route.coordinates
            guard coords.count >= 2 else { continue }

            let segments: [[CLLocationCoordinate2D]]
            if index == selectedIndex || !options.indices.contains(selectedIndex) {
                segments = [coords]
            } else {
                segments = RouteSimilarityAnalyzer.differingSegments(
                    route: coords,
                    reference: options[selectedIndex].coordinates
                )
            }

            for segment in segments where segment.count >= 2 {
                let line = LargusRoutePolyline(coordinates: segment, count: segment.count)
                line.routeIndex = index
                line.isSelected = index == selectedIndex
                mapView.addOverlay(line, level: .aboveRoads)

                if line.isSelected {
                    selectedRect = selectedRect.union(line.boundingMapRect)
                }
            }
        }

        for gap in fuelGaps where gap.coordinates.count >= 2 {
            let overlay = FuelGapPolyline(coordinates: gap.coordinates, count: gap.coordinates.count)
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        if options.indices.contains(selectedIndex) {
            let coords = options[selectedIndex].coordinates
            if let first = coords.first, let last = coords.last {
                mapView.addAnnotations([
                    RouteEndpointAnnotation(
                        coordinate: first,
                        title: "Старт",
                        symbol: "car.fill",
                        tint: .systemBlue
                    ),
                    RouteEndpointAnnotation(
                        coordinate: last,
                        title: "Финиш",
                        symbol: "flag.checkered",
                        tint: .systemRed
                    )
                ])
            }
        }

        coordinator.routeSignature = routeSignature

        if fit, !selectedRect.isNull, !selectedRect.isEmpty {
            mapView.setVisibleMapRect(
                selectedRect,
                edgePadding: NSEdgeInsets(top: 38, left: 38, bottom: 38, right: 38),
                animated: false
            )
        }
    }

    private func refreshPOIs(
        on mapView: MKMapView,
        coordinator: Coordinator
    ) {
        let old = mapView.annotations.compactMap { $0 as? POIAnnotation }
        mapView.removeAnnotations(old)

        mapView.addAnnotations(visiblePOIs.map {
            POIAnnotation(poi: $0, isRecommended: recommendedFuelIDs.contains($0.id))
        })
        coordinator.poiSignature = poiSignature

        // Critical: never change camera here.
        // Layer switches must preserve user's current zoom and pan.
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var routeSignature = ""
        var poiSignature = ""

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            guard let line = overlay as? LargusRoutePolyline else {
                if let gap = overlay as? FuelGapPolyline {
                    let renderer = MKPolylineRenderer(polyline: gap)
                    renderer.strokeColor = .systemOrange
                    renderer.lineWidth = 11
                    renderer.alpha = 0.82
                    renderer.lineDashPattern = [7, 5]
                    return renderer
                }
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            switch line.routeIndex % 3 {
            case 0: renderer.strokeColor = .systemGreen
            case 1: renderer.strokeColor = .systemRed
            default: renderer.strokeColor = .systemBlue
            }

            renderer.lineWidth = line.isSelected ? 8 : 4
            renderer.alpha = line.isSelected ? 1.0 : 0.48
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if !line.isSelected {
                renderer.lineDashPattern = [10, 7]
            }
            return renderer
        }

        private static func smallFuelMarkerImage() -> NSImage {
            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size)
            image.lockFocus()

            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()

            if let symbol = NSImage(
                systemSymbolName: "fuelpump.fill",
                accessibilityDescription: "АЗС"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 9,
                    weight: .bold
                )
            ) {
                let rect = NSRect(x: 4, y: 4, width: 10, height: 10)
                NSColor.white.set()
                symbol.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
            }

            image.unlockFocus()
            return image
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let endpoint = annotation as? RouteEndpointAnnotation {
                let id = "endpoint-\(endpoint.symbol)"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                            as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: endpoint, reuseIdentifier: id)

                view.annotation = endpoint
                view.canShowCallout = true
                view.markerTintColor = endpoint.tint
                view.glyphImage = NSImage(
                    systemSymbolName: endpoint.symbol,
                    accessibilityDescription: endpoint.title
                )
                view.displayPriority = .required
                view.clusteringIdentifier = nil
                return view
            }

            if let poi = annotation as? POIAnnotation {
                if poi.poi.category == .fuel {
                    let id = poi.isRecommended ? "poi-fuel-recommended" : "poi-fuel-small"
                    if poi.isRecommended {
                        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                                    as? MKMarkerAnnotationView)
                            ?? MKMarkerAnnotationView(annotation: poi, reuseIdentifier: id)
                        view.annotation = poi
                        view.canShowCallout = true
                        view.clusteringIdentifier = nil
                        view.displayPriority = .required
                        view.markerTintColor = .systemGreen
                        view.glyphImage = NSImage(
                            systemSymbolName: "fuelpump.fill",
                            accessibilityDescription: "Рекомендуемая АЗС"
                        )
                        return view
                    }
                    let view = mapView.dequeueReusableAnnotationView(
                        withIdentifier: id
                    ) ?? MKAnnotationView(
                        annotation: poi,
                        reuseIdentifier: id
                    )

                    view.annotation = poi
                    view.canShowCallout = true
                    view.clusteringIdentifier = nil
                    view.displayPriority = .required
                    view.image = Self.smallFuelMarkerImage()
                    return view
                }

                let id = "poi-\(poi.poi.category.rawValue)"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                            as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(
                        annotation: poi,
                        reuseIdentifier: id
                    )

                view.annotation = poi
                view.canShowCallout = true
                view.clusteringIdentifier = "route-poi-\(poi.poi.category.rawValue)"
                view.displayPriority = .defaultLow
                view.glyphImage = NSImage(
                    systemSymbolName: poi.poi.category.symbol,
                    accessibilityDescription: poi.poi.category.title
                )

                switch poi.poi.category {
                case .fuel:
                    view.markerTintColor = .systemOrange
                case .hotel:
                    view.markerTintColor = .systemPurple
                case .food:
                    view.markerTintColor = .systemRed
                case .grocery:
                    view.markerTintColor = .systemGreen
                }
                return view
            }

            if let cluster = annotation as? MKClusterAnnotation {
                let id = "route-poi-cluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                            as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: id)

                view.annotation = cluster
                view.markerTintColor = .systemGray
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.canShowCallout = false
                view.displayPriority = .defaultHigh
                return view
            }

            return nil
        }
    }
}

private final class FuelGapPolyline: MKPolyline {}

final class LargusRoutePolyline: MKPolyline {
    var routeIndex = 0
    var isSelected = false
}

final class RouteEndpointAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    let symbol: String
    let tint: NSColor

    init(
        coordinate: CLLocationCoordinate2D,
        title: String,
        symbol: String,
        tint: NSColor
    ) {
        self.coordinate = coordinate
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }
}

final class POIAnnotation: NSObject, MKAnnotation {
    let poi: RoutePOI
    let isRecommended: Bool
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { isRecommended ? "Рекомендуемая: \(poi.name)" : poi.name }

    init(poi: RoutePOI, isRecommended: Bool = false) {
        self.poi = poi
        self.isRecommended = isRecommended
        self.coordinate = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
    }

    var subtitle: String? {
        var parts: [String] = [poi.category.title]

        if let kilometer = poi.roadKilometerLabel {
            parts.append(kilometer)
        } else if poi.category == .fuel {
            parts.append("км трассы: нет данных")
        }

        if poi.distanceFromRouteKM > 0.05 {
            parts.append(String(format: "%.1f км от трассы", poi.distanceFromRouteKM))
        }

        if poi.estimatedDetourMinutes > 0 {
            parts.append("заезд ~\(poi.estimatedDetourMinutes) мин")
        }

        return parts.joined(separator: " · ")
    }

}
