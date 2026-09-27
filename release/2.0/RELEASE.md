# Bikespot London 2.0 release preparation

Prepared 27 September 2026. App Store Connect version 2.0 is a draft, not submitted.

## Branding and version

- App Store name: Bikespot London (previously My Boris Bikes).
- Subtitle: Bikes, spaces and journeys.
- iPhone, Watch and both widget extensions: marketing version 2, build 3 (replacement for rejected upload 2).
- Existing bundle IDs, app group IDs and widget kind IDs are preserved for installed-user compatibility.
- User-facing app, widget, permission and Siri text uses Bikespot London.
- Display-name reference: https://sosumi.ai/documentation/bundleresources/information-property-list/cfbundledisplayname

## What's new

My Boris Bikes is now Bikespot London!

- Journeys: choose your start and destination docks, save regular trips and follow availability along the way.
- Destination updates: keep track of spaces with journey notifications and Live Activities, plus Siri-friendly spoken availability checks.
- Apple Watch Journey widget: check the dock information you need from your wrist.

## Upload rejection resolved in build 3

App Store Connect rejected uploaded build 2 with error 90626 (Invalid Siri Support): the `GetSpacesAtDestinationIntent` description contained the word “Siri”. The same extracted description shipped in the iPhone and Watch apps. Changed “saved Siri destination” to “saved destination”; identifiers, shortcut phrases and runtime behaviour are unchanged. All four shipping targets now use build 3. The rebuilt archive passed signature verification, and all 11 extracted intent descriptions across its shipping bundles were checked for the rejected word. The corrected destination description is present in both the iPhone and Watch metadata. Build 3 requires a fresh distribution upload; the rejected build cannot be repaired in place.

The screenshot gallery predates this metadata-only fix; its visible screens are unchanged.

## Verification completed

- Device archive succeeded at `/Users/mwagstaff/Library/Developer/Xcode/Archives/2026-09-27/Bikespot-London-2.0-build-3.xcarchive` with Apple Development signing. App Store export and validation remain outstanding.
- Fixed the observed Lock Screen contrast issue by keeping the card background and text in a consistent dark appearance. Reference: https://sosumi.ai/documentation/swiftui/view/activitybackgroundtint(_:).
- Fixed a compiler-detected Siri location delegate lifetime issue by keeping the one-shot request alive until completion. Rebuilt the archive successfully; the weak-delegate warning is gone.
- Release simulator build succeeded for iPhone, Watch and both widget extensions, including App Intents metadata extraction.
- All shipping bundles verified as version 2 / build 3 with the new display names.
- 68 Siri availability checks passed.
- 128 journey logic checks passed.
- 32 API tests passed.
- Project plist validation, whitespace checks and recursive archive signature verification passed.
- Existing compiler warnings remain (including future Swift 6 actor isolation and widget switch exhaustiveness); builds complete successfully. These are not represented as warning-free builds.
- Fresh apps installed on paired iPhone 17 Pro Max (iOS 26.5) and Apple Watch Series 11 46mm (watchOS 26.5).

Build products: /tmp/bikespot-release-build/Build/Products

## Screenshot capture checklist

Use actual app screens from the fresh Release build. Keep full native-resolution PNGs, without simulator chrome. Confirm every capture visually before considering it ready to upload.

- [x] iPhone favourites with real dock data
- [x] Map and dock detail
- [x] Journeys overview and journey setup
- [x] Started journey: pickup stage and destination spaces
- [x] Riding stage and destination alternatives
- [x] Lock Screen Live Activity and journey notification
- [x] Siri & Shortcuts availability result
- [x] Live Activity preferences
- [x] About screen showing Bikespot London and version 2
- [x] iPhone Home Screen widgets (small, medium, large)
- [x] Watch favourites and journey screen
- [x] Watch Journey widgets (circular and rectangular)
- [x] Watch Smart Stack journey card
- [ ] iPad key screens, if required by the final App Store media configuration

Do not use the old 15 September simulator build for final release screenshots: it predates the latest Siri and collection-destination changes. The existing App Store screenshots are inherited from version 1.7 and must be reviewed/replaced.

## Capture method and evidence

Device Hub remained unavailable to computer control. With the user's explicit authorization, native XCTest UI automation captured the Release apps on paired iOS 26.5 / watchOS 26.5 simulators. Screenshots use real dock data and a simulated London location; no synthetic availability values were inserted. Temporary command-driven UI tests are removed after capture.

The journey was created and started in the UI, then advanced from pickup bikes to destination spaces. Simulated movement showed 38% direct-line progress. Both Watch complications updated to destination spaces once the pair reconnected. A transient Watch refresh failure recovered on refresh. Siri's in-app availability check returned the active destination count, and a journey availability notification was visible with the Live Activity.

22 visually reviewed screenshots. The test journey was ended through the app after capture; both temporary UI automation methods were removed.

Gallery: [screenshots/index.html](screenshots/index.html). Native PNGs are in `screenshots/iphone` (1320 × 2868) and `screenshots/watch` (416 × 496). The Home Screen captures include other apps installed on this existing simulator. These are review assets; no screenshots have been uploaded to App Store Connect.

## Remaining release gates

- Select the final marketing screenshots from the capture gallery and upload to the appropriate device-size slots. Existing screenshots in App Store Connect are still inherited from version 1.7.
- Export/re-sign the archive for App Store distribution, validate and upload it, then choose the processed build in the version 2.0 draft. The replacement build 3 archive has not been uploaded or validated by App Store Connect; the user-uploaded build 2 was rejected during processing.
- Verify the production API includes the journey progress and destination availability updates required by the app.
- On physical iPhone/Watch, verify destination push notifications, Siri speech, AirPods announcement settings, locked/background behaviour, automatic arrival and ending a journey.
- Check Dynamic Type, VoiceOver, Dark Mode and the smallest supported Watch.
- Review App Privacy and other submission declarations against the actual release behaviour.
- Submit only after these gates are complete. No review submission or production release has been performed.
