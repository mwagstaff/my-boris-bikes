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
