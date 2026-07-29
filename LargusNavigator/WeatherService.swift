import Foundation
import CoreLocation

@MainActor
final class WeatherService {
    func current(place: String, coordinate: CLLocationCoordinate2D) async throws -> WeatherSummary {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(coordinate.latitude)&longitude=\(coordinate.longitude)&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return WeatherSummary(place: place, temperature: response.current.temperature2m, windSpeed: response.current.windSpeed10m, code: response.current.weatherCode)
    }
}

private struct OpenMeteoResponse: Decodable {
    let current: Current
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int
        let windSpeed10m: Double
        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m"
        }
    }
}
