# Testing Journey on Apple Watch

Build and run the iPhone app in Xcode using **Debug** to access the test controls and separate test Live Activity. The paired Watch can use **Debug or Release**: receiving, refreshing and displaying an iPhone test works in both configurations. Local Watch test controls remain Debug-only.

1. Open the Watch app once so it receives the iPhone's journeys and preferences. Allow location for the nearest-dock fallback and real journey progress.
2. Add **BikeSpot London → Journey** to a compatible watch face. Try both a circular and rectangular slot.
3. On iPhone, open **Preferences → Debug → Test a Journey → Start test journey**.
4. Open the Watch Smart Stack and tap the **TEST** Live Activity to open the large Journey screen. While cycling, the dock, large donut, spaces label and progress bar occupy the first page, with no “Open on iPhone” or close button. Swipe up or turn the crown for alternatives, Back to docks and test controls. Tap a Journey complication to open alternatives instead.
5. Change the controls on iPhone and check the following states. Watch-face delivery remains subject to WidgetKit's refresh budget; open the Watch app to see changes immediately.

| Test | Expected result |
| --- | --- |
| Collecting a bike | Home / 🏠; 6 bikes (red only), 4 e-bikes (blue only), or 10 combined bikes (red and blue) according to the test preference |
| Cycling | Station / 🚉; the Watch Smart Stack shows destination spaces plus a separate progress donut on the right, with distance beneath it |
| Spaces = 0, below your saved minimum, at your minimum | Red, orange and green labels respectively; with minimum spaces set to 5, 4 spaces must be orange |
| Position slider | Progress bar changes on the full Watch screen and iPhone activity; both Riding and Arriving cards update destination spaces, percentage and remaining distance; fresh location within 500 metres changes the stage label to Arriving |
| Arrived | Confirmed 100% in the test activity |
| Finished | Live Activity disappears; complications switch to the next scheduled journey's starting dock |
| No journey · favourite | Nearest favourite to the simulated location |
| No favourites · nearest | Nearest dock to the simulated location |
| Stale availability | Last-known indicator; counts are retained |
| Tap complication | Relevant bike or space alternatives; journey actions affect only the test in test mode |

Use **Stop test and restore real data** on iPhone afterwards. Test data expires 30 minutes after the last change and never edits schedules, sends arrival events or creates a real server journey session. The iPhone test activity uses its own ActivityKit type. WatchConnectivity needs a paired, connected device for the iPhone controls to arrive; Smart Stack mirroring also follows the Watch's Live Activity settings.

After updating the launch configuration, install the updated Watch app as well as the iPhone app, then stop and restart the test Live Activity. The Watch Info.plist explicitly registers both Live Activity types and both deep-link schemes. Confirm launch from the Smart Stack with the Watch app closed. The Smart Stack card itself stays compact; tapping it opens the full Watch app screen.

The tap carries the displayed journey independently of WatchConnectivity. With no test fixture synced to the Watch, tapping the cycling test card must still open **TEST · Station**, destination spaces and the progress bar. It must not switch to a nearby dock. A newer synced test replaces the tapped card's older counts and preferences without reopening the screen, including in Release Watch builds. The refresh button requests the latest phone state; the active screen also refreshes every 20 seconds. An expired or stopped test card shows “Activity ended”.

For the reported regression, set minimum bikes and spaces to 5. Start with Bikes selected and 6 bikes, open the Watch Journey screen, then reduce to 3 on iPhone without navigating away on Watch. Check both automatic updates and the refresh button. Home must become a compact orange card, with nearby alternatives underneath and no redundant “Start dock · Low bikes” line. Switch to Cycling with 3 spaces and check Station plus space alternatives. Restore availability above the minimum and check the large dashboard returns. Saved custom alternatives keep their order; automatic alternatives are nearest to the active dock and respect the alternative-filter preference. Watch test journey actions advance or stop only the test, never a real journey.

On iPhone, check that the Lock Screen activity fills the width with a larger donut, dock name, availability label and progress bar. Test a narrow phone size, a long dock alias and larger text sizes. VoiceOver announces approximate progress; stale progress retains its last fill in grey.

Test all three bike preferences—Bikes, E-bikes and Both—using your saved bike/e-bike minimums. During collection, the donut must show only the selected bike types; Both shows the combined count and both coloured segments. The same selector is available in the iPhone and Watch test controls. Change a minimum while testing and check the card, complication, full screen and alternatives agree. The “use minimum thresholds” option for filtering alternative docks must not change label colours.

## Watch Smart Stack card

The small supplemental Live Activity family has its own BikeSpot-branded layout. Collection shows the origin's preferred bike count. Both Riding and Arriving show destination spaces on the left and a separate estimated-completion donut on the right, with distance to the destination beneath it. The approach threshold is 500 metres using a location sample no older than two minutes. Missing or stale location leaves the card in riding mode. Last-updated time is always visible; old or missing dock availability is marked explicitly.

Use the **Position** slider to check both ride stages: 25% shows Riding; 90% shows Arriving. Availability changes must retain the progress display. Distance uses the Watch Favourites format: whole metres below 1,000 metres (for example `850m`), otherwise miles to one decimal place (for example `0.7mi`). Stale progress retains its last value in grey with a clock marker; missing location shows dashes. Always On dims both donuts. Check VoiceOver, increased contrast, and larger text using the previews in `JourneySmartStackCard.swift` and on the smallest supported Watch.

The card performs no polling or networking. It reuses the existing iPhone/ActivityKit and server updates, and renders the latest estimated progress supplied by those updates. The iPhone Lock Screen and Dynamic Island layouts are preserved. No media APIs, audio sessions, or priority overrides are used.

Deploy the updated API alongside the app so background pushes retain journey progress. Old payloads remain compatible; unavailable progress displays dashes. Start a new test activity after installing. Verify finishing, cancelling and automatic arrival remove the activity from both devices. Simulator/source checks cannot verify paired-device presentation, background delivery or final signed Xcode builds.

For a standalone Watch or simulator, open **Watch app → Journey → Test a journey**. These local controls test the Watch views and complications without an iPhone. They do not create a mirrored Smart Stack Live Activity. **Stop Watch test** restores Watch data only; use the iPhone stop button to end its test Live Activity.

## Real-journey checks

After stopping the simulator, verify a scheduled journey and an ad hoc journey. Confirm manual pickup and existing automatic pickup switch from origin bikes to destination spaces. Completion should restore the next eligible departure, including departures days away. Check holiday mode, skipped occurrences, midnight and time-zone changes. The scheduling window remains a pickup window, not a ride-duration estimate.

Disconnect the iPhone after syncing a journey: the open Watch screen should still fetch dock availability and calculate distance from cached journey coordinates. Background Smart Stack progress can lag while disconnected. Turn off location access: a scheduled/active dock should still display, but progress should wait for location; the nearest-dock fallback should request location rather than select an arbitrary dock.

Check the smallest supported Watch size, large Dynamic Type, VoiceOver, a monochrome watch face and Always On display. The chart retains the existing red/blue/grey dock composition, while the selected count and label describe the current journey purpose.

The API changes in `journey-progress.js` and `server.js` must be deployed together for the server's normal Live Activity pushes to retain the latest iPhone progress. The simulator is independent of this deployment. Foreground Watch availability requests run every 20 seconds; watch-face and Smart Stack updates remain system-budgeted. No Xcode build or deployment is performed by these checks.

## Standalone automated checks

The **BikeSpot Journey Paired Check** Xcode scheme runs the iPhone UI regression on the selected paired simulator, without parallel clones. It sets the saved bike/space minimums to 5 through Preferences, then checks 6 → 3 bikes, switching to e-bikes, and 3 → 8 spaces. Each stage pauses for 30 seconds so the open Release Watch app can be inspected. This opt-in scheme leaves the test active; stop it with **Stop test and restore real data** afterwards. The ordinary UI test restores preferences and stops the test automatically.

The Watch test `openJourneyReceivesPhoneEditsWithoutAnotherCardTap` exercises the actual WatchConnectivity receive handler and visible-screen model with an older card context, including newer counts, bike preferences, custom alternative ordering, recovery, and a stopped test. Run it with the Watch scheme's Release Test configuration to cover the original Debug/Release mismatch.

The refresh-reply tests cover a missing phone reply, duplicate/late replies, and cancellation. A phone request stops waiting after eight seconds, retaining cached data and allowing the next refresh; leaving the screen cancels the wait immediately. A late reply still updates the cache. When checking manually, interrupt the phone connection during Refresh and confirm the button does not remain stuck spinning.

Run from the repository root; this compiles only the shared Foundation model and its test runner, not the Xcode project:

```sh
rtk proxy swiftc -D DEBUG \
  'ios/BikeSpot London/BikeSpot London/Models/JourneyComplicationModels.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/JourneyDataSource.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/SiriAvailability.swift' \
  ios/JourneyTests/JourneyLogicChecks.swift -o /tmp/bikespot-journey-checks
rtk proxy /tmp/bikespot-journey-checks
rtk proxy node --test bikespot-london-api/test/*.test.js
```

## Collection destination summary

During collection, verify the Lock Screen, expanded Dynamic Island, Watch Smart Stack and rectangular Journey widget show the start dock on the left and smaller, secondary destination spaces on the right. The circular complication keeps its single start-dock count. Use the journey simulator to change destination spaces, including zero and stale data; confirm the summary disappears when cycling starts. Check long names, larger text, light/dark appearances, increased contrast and VoiceOver using the collection previews and paired devices.

Real journeys require the updated API for background destination refreshes. Confirm a destination-only count change updates the activity, a failed fetch preserves its original timestamp, and missing data displays Unavailable. Confirm no Journey active banner appears in the app; standalone dock notification and holiday banners still work.

## Watch widget tap alternatives

Tap the Watch Smart Stack journey card during collection: it should open a compact list of start-dock alternatives with the selected bike metric (Bikes, E-bikes or Both). After collecting a bike, tap again: it should open destination alternatives with space counts. Repeat using the circular/rectangular Journey complication and the test Live Activity. The current dock stays as a compact summary above the list.

Check custom lists independently for the start and destination: saved order must win over distance, low/zero availability choices remain visible with their threshold colours, and an explicitly empty list must not fall back to automatic suggestions. Without custom choices, nearby alternatives use the selected availability filters. Verify a healthy primary dock is green, low counts orange and zero red. Check switching phase while the list is open, cold-launching the Watch from a Live Activity before phone sync, larger text, and VoiceOver. The test activity should open its own simulated journey rather than a real cached journey.

## Manual next leg

For both scheduled and ad hoc journeys, start at Watching start dock. On iPhone, verify Next leg appears above the dock indicators, shows a progress indicator during the transition and prevents repeated taps; End journey is disabled while it runs. On Watch, verify Next leg and End journey appear at the bottom, below dock information and alternatives, including when availability is loading or unavailable. Tap it on each device and confirm both switch to destination spaces, start the ride timer and remove Next leg. A stale start-dock action must not advance a different journey or restart an already riding journey. A disconnected Watch should report failure without changing the local phase. Repeat with the isolated Watch test journey.

## Unified Watch Journey and cached loading

Widget taps open the root Journey screen directly, combining the active dock, progress, alternatives and bottom actions. Verify there is no second Journey screen behind a back button. Reopen within five minutes: the previous primary and alternative counts should appear immediately with Updated age and Updating latest data while refreshing. A newer tapped activity may seed the primary dock before any network response. Older cached rows must be omitted. On network failure, recent rows remain with a saved-data warning and unchanged retrieval times. Changing bike preferences, thresholds or custom alternatives must invalidate the cached alternative list; advancing to the destination must never show start-dock alternatives. Test app termination/relaunch, offline refresh, larger text, and both real and simulated journeys. Xcode builds and paired-device verification remain manual.

## Journey editing and alternative selection

Run the focused service checks without building the Xcode project:

```sh
swiftc \
  'ios/BikeSpot London/BikeSpot London/Models/BikePoint.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/ScheduledJourney.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/FavoriteJourney.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/AdHocJourney.swift' \
  'ios/BikeSpot London/BikeSpot London/Services/FavoriteJourneyService.swift' \
  'ios/BikeSpot London/BikeSpot London/Services/AdHocJourneyService.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/JourneyHistoryEntry.swift' \
  'ios/BikeSpot London/BikeSpot London/Services/JourneyHistoryService.swift' \
  ios/JourneyTests/JourneyEditingChecks.swift -o /tmp/bikespot-journey-editing-checks
/tmp/bikespot-journey-editing-checks
```

These exercise production journey services with test doubles for Live Activities, server calls and Watch sync. They check favourite persistence and duplicate handling, alternative selection in both phases, stale actions, disabled Live Activities and scheduled-stop failure. They do not exercise ActivityKit or real server connectivity.

After a manual Xcode build, verify:

- Edit a favourite, change either dock, save, and relaunch. Cancel should leave the route unchanged.
- From a map dock, use both journey actions, choose the missing dock, and tap “Start journey”. The app should open Journeys. Repeat while already watching the chosen start dock.
- Open “Edit alternatives” from the map and confirm the saved list is also used in Journeys.
- Select “Start journey here” during collection, then use Next leg. The selected start dock should be watched, followed by the original destination.
- Select “End journey here” during the destination stage. The Live Activity, arrival monitoring and notifications should move to the selected dock without returning to collection.
- For a scheduled trip, the current run stops and continues as an ad-hoc trip; the recurring route remains unchanged. Test loss of network during the stop and confirm an error is shown without starting a second trip.
- Check larger Dynamic Type, VoiceOver and light/dark appearances. The map sheet must scroll to all actions, and alternative actions must wrap with usable touch targets.

## Dock freshness labels and nearby refresh

Favourites, the active iPhone Journey screen, and the Live Activity show **Updated HH:mm** in the device's time zone. The time is the last successful availability fetch, not confirmation that TfL's feed matches the physical dock. Failed requests retain the previous time; cached or seeded Live Activity counts without a known fetch time do not invent one.

Foreground availability refreshes every 30 seconds, or approximately 15 seconds within 500 metres of a displayed dock when location is recent and accurate. Existing arrival-location callbacks also request the monitored dock directly, at most once every 15 seconds within 500 metres. This supplements server pushes when background location delivery is available; it does not guarantee background execution. Server polling remains 15 seconds with a 60-second unchanged-count heartbeat by default.

Build manually in Xcode and verify:
- Favourites, active Journey, Lock Screen, expanded Dynamic Island and Watch Smart Stack show the correct 24-hour time, including with a 12-hour device setting.
- Unchanged counts still advance the time after successful refreshes. Going offline retains the old time.
- Simulated fresh locations inside/outside 500 metres switch foreground cadence; stale/inaccurate location does not enable faster polling.
- Ending or switching a monitored journey cancels/ignores the old dock's pending nearby request.
- Check long dock aliases, larger Dynamic Type, Dark Mode and VoiceOver on device.

Deploy the API change with the app so cached/end pushes preserve the original availability fetch time. iOS push delivery and TfL source freshness can still cause delays.


## Alternative dock browsing

Run from the repository root without an Xcode build:

```sh
swiftc \
  'ios/BikeSpot London/BikeSpot London/Models/BikePoint.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/ScheduledJourney.swift' \
  'ios/BikeSpot London/BikeSpot London/Models/FavoriteBikePoint.swift' \
  'ios/BikeSpot London/BikeSpot London/Services/AlternativeDockSelectionService.swift' \
  ios/JourneyTests/AlternativeDockSelectionChecks.swift -o /tmp/bikespot-alternative-checks
/tmp/bikespot-alternative-checks
```

Checks custom ordering, missing and zero availability, exclusion of custom/primary docks, duplicate IDs, nearest-first ordering, stable distance ties and the 20-dock browsing limit.

After a manual build, check Favourites and each Journey dock's **See all** dialog with a custom list (including an empty custom list). **Other nearby docks** must exclude custom entries without changing them. Verify map donuts persist across zoom levels: close-up labels show preferred bike types without a journey and spaces during a journey. Check the compact Favourites layout, alternative donut charts and full-width End journey buttons with light/dark appearances and larger text.


## Journey history and scheduling

The journey editing checks also cover separate repeat runs, failed starts, completion timestamps, newest-first ordering, merging and history persistence. API history checks cover device isolation, idempotent archiving and cursor pagination, including equal timestamps.

After a manual Xcode build:
- New Journey has a prominent Start journey button and automatically records the run. End it and check the start/end time range in History.
- Repeat a route and take its return: History must retain each run separately. Scroll through more than 30 entries; change All/Favourites/Scheduled/Ad hoc filters.
- Favourites contains favourite routes and schedules. Current appears only during an active journey; there is no separate Scheduled tab.
- Edit a favourite or choose Schedule journey from History, select days/times and save. Edit the schedule, turn Schedule journey off and save: the route remains a favourite, including after relaunch.
- Confirm scheduling errors remain visible and leave the editor open. Test offline history loading and Retry.
- Check large text, VoiceOver and both appearances. Native List creates history rows as they become visible.

Deploy the updated API with the app for background scheduled history. The new journey_history collection retains completed scheduled runs, fetched in pages of 50. Existing local started routes are migrated once; previously discarded trips and unknown end times cannot be reconstructed. History times describe the recorded journey/watch session, not inferred cycling departure or arrival. Removing an active schedule ends its tracked run and keeps the route as a favourite.


### History menu and dock-watch replacement checks

- History → Journey options disables Schedule journey only when a schedule has the same start and end dock IDs in the same direction. The reverse direction remains eligible for its own schedule; sharing only one dock does not count.
- Remove this journey shows confirmation. Cancel preserves it; Remove deletes only that occurrence, preserving favourites/schedules. Refresh and relaunch must not restore it (including server-backed entries).
- A server without `/journey-history` (HTTP 404/501) shows an availability explanation without Retry. Temporary connection/server errors retain Retry, with progress while loading. Pull to refresh checks support again after API deployment.
- Map dock sheet → Watch dock stays available during a journey. Cancel replacement keeps the original run. Confirm stops it, retains the saved route/schedule, then starts a standalone watch, including when selecting the same dock. Test both ad-hoc and scheduled runs and a scheduled-stop network failure.
- Native ActivityKit replacement still requires manual on-device validation.
