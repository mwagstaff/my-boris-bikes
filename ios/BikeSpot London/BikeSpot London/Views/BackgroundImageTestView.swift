#if DEBUG
import SwiftUI

struct BackgroundImageTestView: View {
    @State private var service = LondonBackgroundService.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var baseURL: URL { URL(string: AppConstants.Server.baseURL)! }

    var body: some View {
        Form {
            Section("Live app preview") {
                ZStack(alignment: .topLeading) {
                    BikeSpotBackground()
                    Text("London backgrounds")
                        .font(.title2.bold())
                        .padding()
                }
                .frame(height: 320)
                .clipped()
                .listRowInsets(EdgeInsets())

                if reduceTransparency || contrast == .increased {
                    Text("Your accessibility settings hide background photos in the app and this preview. Downloads and rotation can still be tested below.")
                        .font(.footnote)
                }
                LabeledContent("Displayed image", value: service.debugDisplayedID)
                LabeledContent("Image source", value: service.debugImageSource)
                if let image = service.image {
                    LabeledContent("Decoded size", value: "\(image.width) × \(image.height)")
                }
            }

            Section {
                Button("Refresh Catalogue Now") { run(.refreshCatalog) }
                Button("Next Image") { run(.nextImage) }
                Button("Download Image from Server") { run(.downloadImage) }
                Button("Reload Image from Disk Only") { run(.reloadCachedImage) }
                Button("Clear Background Cache", role: .destructive) { run(.clearCache) }
            } header: {
                Text("Test controls")
            } footer: {
                Text("Refresh bypasses the six-hour wait. Next Image uses the app's rotation order. Download fetches the displayed image's latest server version (or the first server image), even if it is already bundled or cached. These controls change the live app background.")
            }
            .disabled(service.debugIsBusy)

            Section("Result") {
                if service.debugIsBusy {
                    ProgressView("Running…")
                    Button("Cancel") { service.debugCancel() }
                }
                Text(service.debugStatus)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Section("Server and local storage") {
                Text(baseURL.appendingPathComponent("backgrounds").absoluteString)
                    .font(.footnote)
                    .textSelection(.enabled)
                LabeledContent("Server images", value: service.debugCache.catalog.map { "\($0.images.count)" } ?? "Not fetched")
                LabeledContent("Downloaded files", value: "\(service.debugCache.imageCount)")
                LabeledContent("Disk space", value: ByteCountFormatter.string(fromByteCount: Int64(service.debugCache.byteCount), countStyle: .file))
                if let checkedAt = service.debugCache.checkedAt {
                    LabeledContent("Last successful refresh", value: checkedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            Section("What to check") {
                Text("1. Refresh the catalogue, then download an image. The source should say Downloaded and the file count should increase on its first download.")
                Text("2. Reload from disk. The source should say Disk cache. This also works in Airplane Mode.")
                Text("3. Tap Next Image to step through the collection and wrap around. Matching originals use the bundle; new server images download when first shown.")
                Text("4. Publish a changed collection on the server, refresh here, then tap Next Image to test it immediately.")
                Text("5. Clear the cache to test the bundled fallback and start again. Only this server's background files are cleared.")
            }
            .font(.footnote)
        }
        .bikeSpotBackground(showsPhoto: false)
        .navigationTitle("Test Background Images")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.debugRefreshDiagnostics(from: baseURL) }
        .onDisappear { service.debugCancel() }
    }

    private func run(_ action: LondonBackgroundService.DebugAction) {
        let server = baseURL
        Task { await service.debugPerform(action, from: server) }
    }
}
#endif
