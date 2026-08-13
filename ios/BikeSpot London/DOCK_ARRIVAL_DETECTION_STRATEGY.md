# Dock Arrival Detection Strategy

This document describes the approach used in BikeSpot London to detect when a user has arrived at a target dock, with an emphasis on making the feature as sensitive and reliable as possible in real-world iOS conditions.

The same pattern can be reused in other apps that need to detect arrival at a destination, venue, pickup point, parking bay, or other small real-world location.

## Goal

Detect arrival at a known destination while the app may be in the background, and prefer false positives over false negatives within reason.

In this app, the desired outcome is:

- A Live Activity is active for a specific dock.
- The app monitors the user’s progress toward that dock.
- When the user is judged to have arrived, the app ends the Live Activity and unregisters related server-side notifications.

## Why Simple Geofencing Was Not Enough

Region monitoring alone was not reliable enough for a small target like a bike dock in central London.

Practical issues:

- GPS error in dense urban areas is often larger than the dock itself.
- Region entry events can be delayed.
- Reduced Accuracy permission can prevent region monitoring from working reliably.
- A user may briefly cross the geofence boundary without receiving a timely update.
- Waiting for a very precise fix can cause the app to miss arrival entirely.

The working solution is therefore not "geofence only". It is:

1. Use region monitoring as a secondary signal when available.
2. Run a low-cost coarse stream during the destination phase so delayed geofence delivery cannot create a blind spot.
3. Escalate location accuracy in stages as the user approaches the dock.
4. Evaluate arrival using both raw distance and the reported horizontal accuracy envelope.

## Core Design

The monitor uses one target destination at a time.

Each active monitoring session stores:

- `dockId`
- `dockName`
- destination latitude
- destination longitude

When a session starts, the service:

1. Requests the right permissions if needed.
2. Requests temporary full accuracy if the app only has Reduced Accuracy.
3. Starts coarse `CLLocationManager` updates for a journey destination.
4. Optionally starts `CLCircularRegion` monitoring if the platform supports it.
5. Escalates to balanced near-dock updates and then navigation-grade updates for the final approach.
6. Re-checks every fresh location, including batched updates, against an arrival heuristic.

## Permission Model

For background arrival detection on iOS, the feature assumes:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes` includes `location`
- `allowsBackgroundLocationUpdates = true`

To improve real-world precision on iOS 14+, the app also uses:

- `NSLocationTemporaryUsageDescriptionDictionary`
- `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`

This matters because Reduced Accuracy can make region monitoring ineffective and makes small-destination arrival detection much less reliable.

## Tracking Modes

The monitor uses staged accuracy to limit battery use:

- Far from a journey destination: `kCLLocationAccuracyHundredMeters`, a 100m distance filter, and automatic pausing.
- Inside the 500m approach region: `kCLLocationAccuracyNearestTenMeters` with a 20m distance filter.
- Inside the final 200m, expanded by reported uncertainty: `kCLLocationAccuracyBestForNavigation` with no distance filter.

All active profiles use `.otherNavigation`, which matches cycling and does not disable indoor positioning. Background updates and the visible background indicator remain enabled while monitoring is active.

## Region Monitoring Role

Region monitoring is still useful, but only as a helper:

- It provides an additional wake-up/event source.
- It can trigger near-destination logic if iOS delivers it in time.
- It is not treated as the primary arrival mechanism.

The region radius is capped to 500m so the balanced approach profile has time to settle before the final 200m.

Important rule:

- Do not rely on `didEnterRegion` as the only way to escalate monitoring.

For journey destinations, keep a coarse stream active and let region events act as an additional escalation signal.

## Arrival Heuristic

The critical change was to stop treating the reported coordinate as ground truth.

Every location fix includes:

- raw distance to the destination
- horizontal accuracy

The service derives three values:

### 1. Acceptable Horizontal Accuracy

The app ignores fixes that are too poor to be useful.

Current approach:

- Start from `arrivalThreshold + 40m`
- Clamp to a configured minimum and maximum
- Current clamp range: `45m...100m`

This allows the detector to keep working in noisy urban conditions.

### 2. Effective Arrival Threshold

The app expands the arrival threshold when the fix is noisy.

Current approach:

- Start with the user-configured arrival distance.
- Add up to 80% of the excess GPS uncertainty.
- Cap the general-policy expansion at 45m.

Journey ends use a more conservative allowance: half the reported horizontal accuracy, capped at 25m, is added to the configured raw-distance threshold.

This means a nominal 25m arrival threshold can become roughly 41m under realistic GPS noise.

### 3. Compensated Distance

This is the most important part.

The app computes:

`compensatedDistance = max(0, rawDistance - horizontalAccuracy)`

Example:

- Raw distance: `52m`
- Horizontal accuracy: `28m`
- Compensated distance: `24m`

If the uncertainty envelope overlaps the destination strongly enough, the app treats that as a plausible arrival candidate.

This is what made the detector sensitive enough in practice.

## Confirmation Logic

The monitor does not fire on the first plausible fix. It requires a short confirmation window.

Current settings:

- Approach distance: 500m
- Navigation-grade distance: 200m plus a bounded accuracy allowance
- General dwell time: 1.5 seconds
- Journey-end dwell time: 1 second
- Candidate timeout: 30 seconds
- Reset hysteresis: 15m

Interpretation:

- Once the user is plausibly near the destination, the confirmation state begins.
- Two qualifying fixes confirm arrival after the dwell time.
- A single accurate fix clearly inside the configured radius confirms immediately.
- At a journey end, a recent qualifying closest approach followed by walking-speed movement also confirms arrival.
- A fix in the hysteresis band preserves evidence instead of resetting it.
- If the user clearly moves away from the dock, confirmation resets.

Important design choice:

- Keep the dwell time short.

For this feature, long dwell windows caused more missed arrivals than they prevented false positives.

## Hybrid Tracking Beats Either Extreme

An earlier design used:

- low-power tracking at first
- region entry as the trigger for high-power tracking

That design still missed arrivals because:

- region entry was sometimes late
- region entry was sometimes absent
- the user could reach the dock before high-power tracking had enough time to stabilize

The balanced approach is to combine the region monitor with a coarse destination-phase stream, then escalate twice. This preserves an independent approach signal without paying the battery cost of navigation-grade GPS throughout the journey.

## Durable Arrival Delivery

Arrival detection and server acknowledgement are separate operations:

1. Persist a unique arrival event ID.
2. Stop location tracking and end the local Live Activity immediately.
3. Deliver the event to the server.
4. Retry pending events when the app next foregrounds, receives a background push, or obtains its APNs token.

The delivery includes the original Live Activity push token so a delayed retry cannot end a newer activity for the same dock. The server stores successful event IDs for 24 hours and replays the original result for duplicates. A lost HTTP response therefore cannot turn an already-processed arrival into an apparent failure.

## When To Use This Strategy

Use this strategy when all of the following are true:

- the session has a clear start and end
- the destination is known in advance
- missing arrival is costly to the user experience
- battery impact is acceptable for the duration of the session

Good examples:

- arrival at a bike dock
- arrival at a pickup point
- arrival at a car park or charging bay
- arrival at a delivery stop
- arrival at a transit interchange

Less suitable examples:

- all-day passive tracking
- monitoring many destinations simultaneously
- apps where battery minimization matters more than detection sensitivity

## Recommended Implementation Pattern

### Session Start

When the user starts monitoring a destination:

1. Persist the target destination.
2. Request Always authorization if needed.
3. Request temporary full accuracy if needed and possible.
4. Start continuous high-sensitivity updates.
5. Start region monitoring too if available.

### Each Location Update

For each new `CLLocation`:

1. Reject negative accuracy values.
2. Reject fixes worse than the acceptable-accuracy cap.
3. Compute raw distance to the target.
4. Compute compensated distance.
5. Compute the effective arrival threshold.
6. If `min(rawDistance, compensatedDistance)` is within the threshold, enter or continue confirmation.
7. If confirmation stays valid long enough, fire arrival.

### Session End

When arrival is confirmed or the session is canceled:

1. Stop `startUpdatingLocation()`
2. Stop region monitoring
3. Invalidate background activity session
4. Clear persisted monitoring state

## Tuning Guidance

If the detector is still missing arrivals:

- increase maximum accepted horizontal accuracy
- increase maximum arrival-threshold expansion
- decrease dwell time
- increase activation distance
- rely more heavily on compensated distance

If the detector starts firing too early:

- reduce maximum arrival-threshold expansion
- increase dwell time slightly
- require two qualifying updates instead of one short dwell window
- compare both current distance and previous distance to ensure the user is still approaching or stationary

## Tradeoffs

This strategy intentionally biases toward sensitivity.

Benefits:

- far fewer missed arrivals
- less dependence on fragile geofence timing
- better behavior in dense urban GPS conditions

Costs:

- higher battery use
- more background location activity
- higher chance of early confirmation near the destination
- requires clear privacy messaging and user trust

For apps with a short-lived destination-monitoring session, this is usually acceptable.

## Apple APIs And Documentation Worth Reviewing

- [`CLLocationManager.allowsBackgroundLocationUpdates`](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)
- [`CLLocationManager.desiredAccuracy`](https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy)
- [`CLLocationManager.distanceFilter`](https://developer.apple.com/documentation/corelocation/cllocationmanager/distancefilter)
- [`CLLocationManager.activityType`](https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype)
- [`CLLocationManager.startMonitoring(for:)`](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:))
- [`CLLocationManager.accuracyAuthorization`](https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization)
- [`CLLocationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requesttemporaryfullaccuracyauthorization(withpurposekey:))
- [Configuring your app to use location services](https://developer.apple.com/documentation/corelocation/configuring-your-app-to-use-location-services)
- [Monitoring the user’s proximity to geographic regions](https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)

## Short Version

If you want small-destination arrival detection on iOS to be genuinely reliable:

- do not rely on geofencing alone
- run continuous navigation-grade updates during the active session
- request full accuracy when possible
- evaluate arrival using GPS uncertainty, not only the raw point estimate
- keep confirmation short
- accept the battery tradeoff explicitly

That combination is what made the feature work reliably here.
