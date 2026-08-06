import Foundation
import Combine

class BannerService: ObservableObject {
    static let shared = BannerService()

    @Published var currentBanner: BannerConfig?

    private let bannerURL = "https://mwagstaff.github.io/status-pages/app-banners/my-boris-bikes.json"
    private let cacheKey = "cachedBannerConfig"
    private let cacheTimestampKey = "cachedBannerTimestamp"
    private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
    private let requestTimeout: TimeInterval = 5.0 // Fast timeout as requested

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadCachedBanner()
    }

    func fetchBannerConfig() {
        guard let url = URL(string: bannerURL) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: config)

        session.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: BannerConfig.self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure = completion {
                        // Fetch failed, use cached value if available and recent
                        self?.loadCachedBannerIfRecent()
                    }
                },
                receiveValue: { [weak self] banner in
                    // Successfully fetched, cache and update UI
                    self?.cacheBanner(banner)
                    self?.updateBanner(banner)
                }
            )
            .store(in: &cancellables)
    }

    private func updateBanner(_ banner: BannerConfig) {
        // Only show banner if enabled
        if banner.enabled {
            currentBanner = banner
        } else {
            currentBanner = nil
        }
    }

    private func cacheBanner(_ banner: BannerConfig) {
        if let encoded = try? JSONEncoder().encode(banner) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
        }
    }

    private func loadCachedBanner() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let banner = try? JSONDecoder().decode(BannerConfig.self, from: data) else {
            return
        }

        // Load cached banner regardless of age on initial load
        updateBanner(banner)
    }

    private func loadCachedBannerIfRecent() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let banner = try? JSONDecoder().decode(BannerConfig.self, from: data),
              let timestamp = UserDefaults.standard.object(forKey: cacheTimestampKey) as? TimeInterval else {
            // No valid cache, hide banner
            currentBanner = nil
            return
        }

        let cacheAge = Date().timeIntervalSince1970 - timestamp

        // Only use cached banner if it's recent (within expiration interval)
        if cacheAge < cacheExpirationInterval {
            updateBanner(banner)
        } else {
            // Cache too old, hide banner
            currentBanner = nil
        }
    }

    func clearBanner() {
        currentBanner = nil
    }
}
