import Foundation
import Network
import Combine

class TfLAPIService {
    static let shared = TfLAPIService()
    
    private let session: URLSession
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    @Published var isOnline = true
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        
        startNetworkMonitoring()
    }
    
    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    func fetchAllBikePoints(cacheBusting: Bool = false) -> AnyPublisher<[BikePoint], NetworkError> {
        guard isOnline else {
            return Fail(error: NetworkError.offline)
                .eraseToAnyPublisher()
        }
        
        var urlString = AppConstants.API.baseURL + AppConstants.API.bikePointEndpoint
        if cacheBusting {
            let timestamp = Int(Date().timeIntervalSince1970)
            urlString += "?cb=\(timestamp)"
        }
        
        guard let url = URL(string: urlString) else {
            return Fail(error: NetworkError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        if cacheBusting {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        
        return session.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: [FailableDecodable<BikePoint>].self, decoder: JSONDecoder())
            .map { $0.compactMap(\.value) }
            .mapError { error in
                if error is DecodingError {
                    return NetworkError.decodingError(error)
                } else {
                    return NetworkError.networkError(error)
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func fetchBikePoint(id: String, cacheBusting: Bool = false) -> AnyPublisher<BikePoint, NetworkError> {
        guard isOnline else {
            return Fail(error: NetworkError.offline)
                .eraseToAnyPublisher()
        }
        
        var urlString = AppConstants.API.baseURL + AppConstants.API.placeEndpoint + "/\(id)"
        if cacheBusting {
            let timestamp = Int(Date().timeIntervalSince1970)
            urlString += "?cb=\(timestamp)"
        }
        
        guard let url = URL(string: urlString) else {
            return Fail(error: NetworkError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        if cacheBusting {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        
        return session.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: BikePoint.self, decoder: JSONDecoder())
            .mapError { error in
                if error is DecodingError {
                    return NetworkError.decodingError(error)
                } else {
                    return NetworkError.networkError(error)
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func fetchMultipleBikePoints(ids: [String], cacheBusting: Bool = false) -> AnyPublisher<[BikePoint], NetworkError> {
        let publishers = ids.map { fetchBikePoint(id: $0, cacheBusting: cacheBusting) }
        
        return Publishers.MergeMany(publishers)
            .collect()
            .eraseToAnyPublisher()
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
