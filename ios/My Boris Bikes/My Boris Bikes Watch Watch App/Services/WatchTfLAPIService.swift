import Foundation
import Combine

class WatchTfLAPIService: ObservableObject {
    static let shared = WatchTfLAPIService()
    
    private let session = URLSession.shared
    private let baseURL = "https://api.tfl.gov.uk"
    private let bikePointEndpoint = "/BikePoint"
    
    // Rate limiting and caching
    private let minimumRequestInterval: TimeInterval = 2.0 // 2 seconds between requests to reduce rate limiting
    private var lastRequestTime: Date = Date.distantPast
    private var requestQueue = DispatchQueue(label: "watchapi.queue", qos: .utility)
    private var cache: [String: (data: WatchBikePoint, timestamp: Date)] = [:]
    private let cacheExpirationInterval: TimeInterval = 60.0 // 60 seconds - longer cache to reduce API calls
    private var pendingRequests: [String: AnyPublisher<WatchBikePoint, WatchNetworkError>] = [:]
    
    private init() {}
    
    func fetchBikePoint(id: String, cacheBusting: Bool = false) -> AnyPublisher<WatchBikePoint, WatchNetworkError> {
        let cacheKey = cacheBusting ? "\(id)_bust_\(Int(Date().timeIntervalSince1970))" : id
        
        // Check if we have a pending request for this ID (only if not cache busting)
        if !cacheBusting, let existingPublisher = pendingRequests[id] {
            return existingPublisher
        }
        
        // Check cache first (skip if cache busting)
        if !cacheBusting, let cached = cache[id], Date().timeIntervalSince(cached.timestamp) < cacheExpirationInterval {
            return Just(cached.data)
                .setFailureType(to: WatchNetworkError.self)
                .eraseToAnyPublisher()
        }
        
        var urlString = baseURL + bikePointEndpoint + "/\(id)"
        if cacheBusting {
            let timestamp = Int(Date().timeIntervalSince1970)
            urlString += "?cb=\(timestamp)"
        }
        
        guard let url = URL(string: urlString) else {
            return Fail(error: WatchNetworkError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        
        let publisher = throttledRequest(for: url, id: id, cacheBusting: cacheBusting)
            .handleEvents(receiveSubscription: { _ in
            }, receiveOutput: { data, response in
                if let httpResponse = response as? HTTPURLResponse {
                    
                    // Handle rate limiting
                    if httpResponse.statusCode == 429 {
                        if let retryAfter = httpResponse.allHeaderFields["Retry-After"] as? String,
                           let retrySeconds = Int(retryAfter) {
                        }
                    }
                }
                // Debug: Print first 200 characters of response
                if let jsonString = String(data: data, encoding: .utf8) {
                    let preview = String(jsonString.prefix(200))
                }
            }, receiveCompletion: { completion in
                if case .failure(let error) = completion {
                }
                // Remove from pending requests when complete
                self.pendingRequests.removeValue(forKey: id)
            })
            .tryMap { data, response -> Data in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WatchNetworkError.networkError(URLError(.badServerResponse))
                }
                
                if httpResponse.statusCode == 429 {
                    throw WatchNetworkError.rateLimited
                }
                
                guard httpResponse.statusCode == 200 else {
                    throw WatchNetworkError.httpError(httpResponse.statusCode)
                }
                
                return data
            }
            .decode(type: WatchBikePoint.self, decoder: JSONDecoder())
            .handleEvents(receiveOutput: { bikePoint in
                // Cache the successful result
                self.cache[id] = (data: bikePoint, timestamp: Date())
            })
            .mapError { error in
                if error is DecodingError {
                    return WatchNetworkError.decodingError(error)
                } else if let networkError = error as? WatchNetworkError {
                    return networkError
                } else {
                    return WatchNetworkError.networkError(error)
                }
            }
            .receive(on: DispatchQueue.main)
            .retry(2) // Retry up to 2 times for network errors
            .eraseToAnyPublisher()
        
        // Store pending request
        pendingRequests[id] = publisher
        
        return publisher
    }
    
    func fetchMultipleBikePoints(ids: [String], cacheBusting: Bool = false) -> AnyPublisher<[WatchBikePoint], WatchNetworkError> {
        if cacheBusting {
        } else {
        }
        
        // Check cache status
        let cacheStatus = getCacheStatus()
        
        // Use parallel approach for better performance
        return fetchBikePointsInParallel(ids: ids, cacheBusting: cacheBusting)
    }
    
    func fetchSingleBikePoint(id: String, cacheBusting: Bool = false) -> AnyPublisher<WatchBikePoint?, WatchNetworkError> {
        if cacheBusting {
        } else {
        }
        
        return fetchBikePoint(id: id, cacheBusting: cacheBusting)
            .map { Optional($0) }
            .catch { error -> AnyPublisher<WatchBikePoint?, Never> in
                return Just(nil).eraseToAnyPublisher()
            }
            .setFailureType(to: WatchNetworkError.self)
            .eraseToAnyPublisher()
    }
    
    private func throttledRequest(for url: URL, id: String, cacheBusting: Bool = false) -> AnyPublisher<(Data, URLResponse), URLError> {
        return Future<(Data, URLResponse), URLError> { promise in
            self.requestQueue.async {
                let now = Date()
                let timeSinceLastRequest = now.timeIntervalSince(self.lastRequestTime)
                
                if timeSinceLastRequest < self.minimumRequestInterval {
                    let delay = self.minimumRequestInterval - timeSinceLastRequest
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.performRequest(url: url, id: id, cacheBusting: cacheBusting, promise: promise)
                    }
                } else {
                    self.performRequest(url: url, id: id, cacheBusting: cacheBusting, promise: promise)
                }
            }
        }.eraseToAnyPublisher()
    }
    
    private func performRequest(url: URL, id: String, cacheBusting: Bool = false, promise: @escaping (Result<(Data, URLResponse), URLError>) -> Void) {
        lastRequestTime = Date()
        if cacheBusting {
        } else {
        }
        
        var request = URLRequest(url: url)
        if cacheBusting {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError {
                promise(.failure(error))
            } else if let data = data, let response = response {
                promise(.success((data, response)))
            } else {
                promise(.failure(URLError(.unknown)))
            }
        }.resume()
    }
    
    func clearCache() {
        cache.removeAll()
    }
    
    func getCacheStatus() -> (count: Int, oldestAge: TimeInterval?) {
        let now = Date()
        let ages = cache.values.map { now.timeIntervalSince($0.timestamp) }
        return (count: cache.count, oldestAge: ages.max())
    }
    
    private func fetchBikePointsInParallel(ids: [String], cacheBusting: Bool = false) -> AnyPublisher<[WatchBikePoint], WatchNetworkError> {
        guard !ids.isEmpty else {
            return Just([])
                .setFailureType(to: WatchNetworkError.self)
                .eraseToAnyPublisher()
        }
        
        
        // Create publishers for all bike points in parallel
        let publishers = ids.map { id in
            fetchBikePoint(id: id, cacheBusting: cacheBusting)
                .map { Optional($0) }
                .catch { error -> AnyPublisher<WatchBikePoint?, Never> in
                    return Just(nil).eraseToAnyPublisher()
                }
        }
        
        // Combine all publishers and wait for all to complete
        return Publishers.MergeMany(publishers)
            .collect() // Collect all results
            .map { results -> [WatchBikePoint] in
                let validResults = results.compactMap { $0 }
                return validResults
            }
            .setFailureType(to: WatchNetworkError.self)
            .eraseToAnyPublisher()
    }
    
    private func fetchBikePointsSerially(ids: [String]) -> AnyPublisher<[WatchBikePoint], WatchNetworkError> {
        guard !ids.isEmpty else {
            return Just([])
                .setFailureType(to: WatchNetworkError.self)
                .eraseToAnyPublisher()
        }
        
        let firstId = ids[0]
        let remainingIds = Array(ids.dropFirst())
        
        return fetchBikePoint(id: firstId)
            .map { Optional($0) }
            .catch { error -> AnyPublisher<WatchBikePoint?, Never> in
                return Just(nil).eraseToAnyPublisher()
            }
            .flatMap { firstResult -> AnyPublisher<[WatchBikePoint], WatchNetworkError> in
                if remainingIds.isEmpty {
                    return Just([firstResult].compactMap { $0 })
                        .setFailureType(to: WatchNetworkError.self)
                        .eraseToAnyPublisher()
                } else {
                    return self.fetchBikePointsSerially(ids: remainingIds)
                        .map { remainingResults in
                            return [firstResult].compactMap { $0 } + remainingResults
                        }
                        .eraseToAnyPublisher()
                }
            }
            .handleEvents(receiveOutput: { bikePoints in
            })
            .eraseToAnyPublisher()
    }
}

struct WatchBikePoint: Codable, Identifiable, Hashable {
    let id: String
    let commonName: String
    var alias: String?
    let lat: Double
    let lon: Double
    let additionalProperties: [WatchAdditionalProperty]
    
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        return commonName
    }
    
    var standardBikes: Int {
        Int(additionalProperties.first { $0.key == "NbStandardBikes" }?.value ?? "0") ?? 0
    }
    
    var eBikes: Int {
        Int(additionalProperties.first { $0.key == "NbEBikes" }?.value ?? "0") ?? 0
    }
    
    var totalDocks: Int {
        Int(additionalProperties.first { $0.key == "NbDocks" }?.value ?? "0") ?? 0
    }
    
    /// Raw number of empty docks from API
    private var rawEmptyDocks: Int {
        Int(additionalProperties.first { $0.key == "NbEmptyDocks" }?.value ?? "0") ?? 0
    }
    
    var totalBikes: Int {
        standardBikes + eBikes
    }
    
    /// Number of broken docks calculated from API data
    /// Formula: nbDocks - (nbBikes + nbSpaces) != 0 indicates broken docks
    var brokenDocks: Int {
        let calculatedBrokenDocks = totalDocks - (totalBikes + rawEmptyDocks)
        let brokenCount = max(0, calculatedBrokenDocks)
        return brokenCount
    }
    
    /// Adjusted number of empty docks, accounting for broken docks
    /// This is the number of spaces actually available to users
    var emptyDocks: Int {
        // If there are broken docks, we should not show them as available spaces
        // The raw empty docks should already exclude broken ones, but we verify the calculation
        let expectedTotal = totalBikes + rawEmptyDocks + brokenDocks
        
        if expectedTotal == totalDocks {
            // Data is consistent, return raw empty docks
            return rawEmptyDocks
        } else {
            // Data inconsistency detected, calculate adjusted empty docks
            let adjustedEmpty = totalDocks - totalBikes - brokenDocks
            return max(0, adjustedEmpty)
        }
    }
    
    var isAvailable: Bool {
        let isInstalled = additionalProperties.first { $0.key == "Installed" }?.value == "true"
        let isLocked = additionalProperties.first { $0.key == "Locked" }?.value == "true"
        return isInstalled && !isLocked
    }
    
    /// Indicates whether this dock has any broken docks
    var hasBrokenDocks: Bool {
        brokenDocks > 0
    }
}

struct WatchAdditionalProperty: Codable, Hashable {
    let key: String
    let value: String
}

enum WatchNetworkError: LocalizedError {
    case invalidURL
    case noData
    case decodingError(Error)
    case networkError(Error)
    case rateLimited
    case httpError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noData:
            return "No data received"
        case .decodingError(let error):
            return "Data parsing error: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimited:
            return "Rate limit exceeded. Please wait before trying again."
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        }
    }
}
