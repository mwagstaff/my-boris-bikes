# London background checks

Run the lifecycle and disk-cache checks from the repository root without an Xcode build:

```sh
bash ios/BackgroundTests/run-checks.sh
```

This uses the installed Swift compiler and Node to run a loopback-only fixture. It checks rotation, catalogue reordering/removals, on-demand downloading, cache hits, offline restart, version changes, corrupt local and remote data, size limits, cancellation, path validation and cache eviction. It does not contact production or require APNs credentials.

It also compiles the service with `DEBUG` and checks forced catalogue refreshes, forced downloads of identical bundled/cached images, a complete rotation cycle, disk-only reloads with no network requests, failure retention, cancellation and cache reset.

API routes and publication are covered by `npm test` in `bikespot-london-api`.

## Debug screen

In a Debug build, open **Preferences → Debug → Test Background Images**. The screen, diagnostics and test hooks are enclosed in `#if DEBUG` and are absent from Release builds. It uses the existing API Environment preference and shows the exact catalogue URL. The API background routes must be deployed (or running locally); `localhost:3010` works with the Simulator, but a physical iPhone's localhost refers to the phone itself.

1. Tap **Refresh Catalogue Now**. This bypasses the normal six-hour refresh and five-minute retry waits. The server image count and last successful refresh should update; the current image stays visible.
2. Tap **Download Image from Server**. This performs a real request even when the bytes match a bundled or cached image. The source should say **Downloaded**, with successful size/hash/decoding validation. Repeating it downloads again, while the stored-file count stays unchanged for the same version. If the current ID is absent from the server catalogue, it downloads the first entry.
3. Tap **Reload Image from Disk Only**. The source should say **Disk cache**. Enable Airplane Mode through Control Centre and repeat to verify offline reuse without rotating to another image. A missing or invalid cached file reports a miss without falling back to a network request.
4. Tap **Next Image** to exercise the same selection and loading path used on foreground visits. It wraps at the end. Original, unchanged images report **Bundled**; new server entries report **Downloaded** on first use and **Disk cache** on reuse. The preview and app tabs share the displayed image.
5. Publish additions, replacements or removals, then refresh and advance to test the changed collection without waiting or relaunching.
6. Tap **Clear Background Cache** to remove this API environment's downloaded images and catalogue, restore a bundled fallback, and reset the refresh timers. Other environments and app data are preserved.

Failed requests retain the current display and previously validated files. Cancel a running request with **Cancel**; leaving the screen or backgrounding the app also cancels it. Light/dark appearance and accessibility settings apply to the live preview just as they do in the app. These controls do not enable a persistent test mode.

## Manual app checks

After deploying the API and building manually in Xcode:

- Check the same landmark appears across Favourites, Journeys, Profile and About. Switch tabs and open/dismiss sheets; the image should remain stable. Preferences and other forms retain their plain backgrounds.
- Background and reopen the app to advance. All catalogue images appear before repeating, and relaunching continues the sequence using stable image IDs.
- Open and close Control Centre or a permission prompt; temporary inactivity must not advance the image.
- Check light and dark appearance on a small and large iPhone. Dark uses the approved 72% opacity, with the mask fully opaque through 55% of the header, then 85% at 80% height before fading out. Light retains 34% opacity and its original fade. Check navigation-title readability over the brightest images as well as visibility of darker scenes.
- Check larger Dynamic Type and VoiceOver. The background remains decorative, while content and controls remain readable.
- Enable Reduce Transparency or Increase Contrast: the image should disappear in favour of the system background. There is no timed rotation or animation, including with Reduce Motion enabled.

Also check a newly published remote image, replacement of an existing image ID, server unavailability, airplane mode, and relaunch after the disk cache has been removed. The current background remains visible during downloads. A successful catalogue refresh applies to the next visit; normal refreshes are six hours apart. Compare a remote image in both appearances and with the accessibility settings above.

The twelve bundled JPEGs retain the approved 1536 × 1024 compositions and provide offline fallbacks. `LondonBackgrounds.json` records their hashes so unchanged images are not downloaded again. Keep that bundled manifest in sync if replacing bundled assets in a future app release; changing server images does not require changing it.

The server collection now contains 37 images. After publishing it, use the Debug screen to refresh the catalogue and confirm **Server images: 37**. Advance to a newly added landmark: its first appearance should report **Downloaded**, and later appearances should report **Disk cache**. The new images are intentionally absent from the app's bundled asset catalogue.

Full-resolution review originals remain in `output/london-background-review/` outside the app target. The editable publishing source set is in `output/london-background-source/`. See the API README for publication and persistent server-directory setup.
