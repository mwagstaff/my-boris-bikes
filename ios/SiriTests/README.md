# Siri availability — implementation and release checks

## Implemented scope (Phases 0–5)

The two dynamic actions are **Get Spaces at Destination** and **Get Bikes at Start**. They return an integer and a spoken dialog from one validated response, with a static result card. **Get Spaces at Dock** and **Get Bikes at Dock** take a stable station entity for explicitly configured Shortcuts. All four are read-only, run without foregrounding the app, and are compiled into the iPhone and Watch applications. Existing widget/control intents and their identifiers/parameters are unchanged. Section 12 remains follow-on work.

The source implementation and local verification are complete once the checks below pass; signed builds, App Intents metadata extraction and physical Siri acceptance remain release gates. No real-device validation or deployment is claimed.

## Personal shortcuts: exact short names

On iPhone, open **Preferences → Siri & Shortcuts**. An active journey supplies both roles. Without a journey, bikes uses the nearest favourite and spaces uses the saved Siri destination configured here.

### How many spaces

1. Open Shortcuts and create a new shortcut.
2. Add BikeSpot London's **Get Spaces at Destination** action.
3. Keep this dynamic action, rather than **Get Spaces at Dock** or a copied station ID.
4. Name the shortcut exactly **How many spaces**.
5. Say **“Hey Siri, how many spaces?”** while stationary.

### How many bikes

1. Create another shortcut with BikeSpot London's **Get Bikes at Start** action.
2. Keep the dynamic action: it uses the active start, or the nearest favourite when there is no journey.
3. Name it exactly **How many bikes**.
4. Say **“Hey Siri, how many bikes?”** while stationary.

Each shortcut should initially contain only its one action. Check that Siri speaks the complete dock/count/role once. Do not add Open App, Show Result or Speak Text as prerequisites. Enable **Show on Apple Watch** in each personal shortcut's details to test Watch invocation. The app does not install these personal shortcuts or claim ownership of generic phrases.

Built-in fallbacks are **“How many spaces in BikeSpot London?”** and **“How many bikes in BikeSpot London?”**. The app's Shortcuts link opens discovery; it does not mean the personal shortcuts have been installed. Availability can change before arrival.

## Phase 0 integration audit

Project: `ios/BikeSpot London/BikeSpot London.xcodeproj`.

| Existing component | Reuse |
| --- | --- |
| `JourneySnapshot`, `JourneyRun`, `JourneyDock`, `JourneyStore` | Atomic persisted role snapshot and stable TfL IDs in the existing App Group; no view or scene dependency |
| `JourneySyncService`, `ScheduledJourneyService`, `AdHocJourneyService`, `LiveActivityService` | Existing active/ended journey lifecycle, reversals and selections; Siri never uses the phase-dependent widget selector |
| `JourneyDataSource`, `APIJourneyDock` | Existing cross-platform direct TfL BikePoint request path, now with validated keyed optional counts and a bounded request seam |
| `FavoritesService`, `DockPreferencesService`, dock index | Favourite identities and coordinates; no new favourites store |
| `WatchFavoritesService`, `JourneyStore.syncPayload` | Existing Watch Connectivity delegate, reply deadline and full application-context payload |
| `DockPickerView`, `PreferencesView` | Native destination picker, setup/help and test lookup surface |
| Existing App Intents | Widget configuration, open-dock and timer control identities remain untouched; there was no availability AppShortcutsProvider to extend |

Installed compiler: Apple Swift 6.3.3; project uses Swift 5 language mode. Installed iPhoneOS/watchOS SDKs are 26.5. Deployment settings are preserved: iPhone application/widget 18.5, iPhone test targets 18.6, Watch application/extension/tests 11.5; inherited project settings remain unchanged. Existing schemes include BikeSpot London, BikeSpot London Watch App, BikeSpot London Watch App Extension, and BikeSpot Journey Paired Check.

The new App Intents are in the application targets, not a new extension. System routing chooses the execution device; a phone invocation uses the phone process/store, and a Watch invocation uses the Watch process/store and direct TfL networking. Actual Siri device routing must be observed on hardware. Existing App Group membership is reused locally on each device; it does not synchronise phone and Watch. No new permission, entitlement, background mode, package, backend or deployment target was added.

## Resolution and lifecycle

- An explicit entity overrides all context without editing it.
- With one active journey, bikes always uses its start and spaces its destination, during both pickup and riding. A missing/invalid role fails instead of borrowing a default.
- Multiple active journey identities fail until the user ends the extras; Siri never chooses the first one.
- Without an active journey, bikes uses the geometrically nearest **favourite**, independent of sorting, temporary bike filters or upcoming schedules. This user-requested fallback intentionally supersedes the plan's no-nearest rule. No favourite means a setup error, never a nearby non-favourite.
- Nearest-favourite selection requires all candidate coordinates and a location no more than 120 seconds old, with accuracy at most 100 metres. An existing Core Location grant permits a one-shot fix with a two-second allowance; Siri does not request a new grant. Missing coordinates may be resolved through the existing catalogue within the overall deadline.
- Without an active journey, spaces uses only the explicitly saved Siri destination. There is no competing saved start setting, because the requested fallback is nearest favourite.
- The phone alone edits the saved Siri destination. Optional schema fields live inside `JourneySnapshot`; nil is an explicit clear. Existing snapshots decode without assigning favourites to roles. No historical journey is migrated into a default.
- The persisted snapshot's `generatedAt` revision is captured with station identity, role and name. A changed snapshot is resolved/fetched once more within the original deadline; repeated change fails.
- Existing end/cancel markers are retained. Ended Live Activity IDs are additionally persisted, preventing a still-visible ended activity from becoming current after relaunch. Normal expiry uses the existing eight-hour journey lifecycle.

## Availability and freshness

`NbBikes` is the total; `NbEmptyDocks` is the return-space count. Key ordering is irrelevant. Missing, malformed, negative, overflowing and conflicting duplicate counts are unknown. Zero remains a successful value. The standard/electric breakdown is spoken only when both are valid and sum to the independently supplied total. All-electric availability is explicit. Capacity is never used to manufacture spaces or subtract broken docks again.

The shared parser preserves property `modified` strings as provider metadata. It does not treat them as observation or retrieval time. Existing non-Siri `BikePoint` integer display contracts are unchanged; the validated shared adapter is used for Siri. Existing `Installed=false` or `Locked=true` handling is retained; uncertain flags do not become invented closure reasons. All success dialogs say **“TfL reports…”**.

Every invocation attempts a direct current request. The request ignores local cache and requests revalidation; any returned HTTP `Age` is subtracted from receipt time. A report older than 30 seconds fails distinctly as stale. Missing HTTP Age on a successful direct TfL response is treated as a new retrieval of a provider report, not proof of feed observation age. No backend download or complication cache is labelled fresh. Old local availability is never a numerical fallback. Network, timeout, rate-limit, malformed-response, wrong-identity, unavailable-station and missing-metric failures return no integer. No sentinel zero/-1 is returned.

The overall runtime budget is eight seconds, including up to two seconds for phone confirmation or location. Network work has an explicit deadline and cancellation. The only retry is for one selection change; there is no automatic retry of rate limits or server errors. The result card makes no request and starts no polling. The existing journey client did not coalesce requests; this implementation does not add speculative caching or coalescing.

## Watch and privacy

Watch requests the existing journey-state reply before looking up TfL. A successful reply must contain the current schema and a revision at least as new as the local snapshot. Older/equal incoming state cannot replace newer data. All Siri fields are inside the existing snapshot, so the application-context payload retains favourites, preferences, location, availability and simulation data.

When phone confirmation fails, a supported persisted context can still be checked over the Watch network, but the spoken role explicitly says **last synced**. This may be an old destination; it is never presented as confirmed current. Missing/old-schema context fails with sync guidance. A confirmed clear overrides an older selected destination. Watch edits of Siri defaults are not supported. No-network Watch execution cannot substitute complication counts. Independent Watch Siri support remains unverified until the physical tests pass.

The actions explicitly use `alwaysAllowed` authentication for hands-free, read-only checks, subject to system Siri settings and protected storage availability. The help screen discloses that dock names can be spoken while locked. No new location grant, audio capture or tracking is added. Location permission is needed only for nearest favourite; active/explicit roles work without it.

## Local verification

Repository instructions prohibit `xcodebuild`; the user runs signed Xcode builds manually.

```sh
rtk proxy python3 ios/SiriTests/check.py
rtk proxy python3 ios/SiriTests/check.py --typecheck
rtk git diff --check
```

The runner compiles/runs the shared Foundation tests with `swiftc`, then optionally type-checks every iPhone app source at iOS 18.5, every Watch app source in Debug and Release at watchOS 11.5, the Watch extension, and the iPhone widget. It saves diagnostics to `/tmp/bikespot-*-typecheck.log`. It does not link/sign applications or run App Intents metadata extraction. All fixture names/counts are synthetic, and the HTTP adapter tests use an injected URLSession/URLProtocol without live TfL counts.

Covered: role precedence, same-dock trips, missing/ambiguous/expired journeys, favourites, location expiry, explicit override, saved/cleared/reloaded state, revision ordering, legacy decoding, optional/keyed metrics, duplicates, broken-capacity fixture, singular/plural/zero/all-electric speech, old modified/new retrieval, old HTTP cache age, malformed age, HTTP 401/403/404/429/500/503, malformed body, hanging request deadline, cancellation, and one/repeated selection races.

### Results on 16 September 2026

- `rtk proxy python3 -u ios/SiriTests/check.py --typecheck`: **66 Siri checks and 125 existing Journey checks passed**. iPhone app, Watch app Debug/Release, Watch extension and iPhone widget source type-checks passed at the unchanged minimum OS versions. Existing unused-variable, deprecated-API and concurrency warnings remain outside this change.
- The Watch Debug/Release checks were repeated after limiting the strict Siri-context validation to Siri callers; ordinary Watch refresh callers retain their previous reply behaviour.
- `rtk git diff --check`: passed.
- `rtk proxy plutil -lint 'ios/BikeSpot London/BikeSpot London.xcodeproj/project.pbxproj'`: passed.
- No `xcodebuild`, signed app build, App Intents metadata extraction, installed Shortcut run or physical-device test was performed. These are the remaining release gates below.

### Xcode checks still required

1. Build/install iPhone and Watch Debug and Release using the existing schemes and minimum supported OS destinations. Build both widget extensions; run the existing iPhone/Watch tests, including the Watch reply cancellation/late-reply tests.
2. Inspect App Intents metadata extraction and Shortcuts discovery: all four actions, stable explicit entity IDs, the two built-in phrases and integer outputs.
3. Re-run previously saved widget/control Shortcuts. Add personal shortcuts using the recipes above; verify error dialogs carry the meaningful localised message and no number.
4. Check Preferences and result cards in Light/Dark Mode, largest Dynamic Type, VoiceOver, long station names and smallest Watch. Strings use LocalizedStringResource/String(localized:) and native SwiftUI localisation; this English-only repository had no translation catalogue. Translation extraction and non-English Siri are unverified.

## Physical-device matrix — all outstanding

For **each** row record: hardware, OS, app build, Siri language, input phrase, actual execution device, resolved station, full spoken result, foregrounding, latency and pass/fail. Test while stationary.

| Scenario | Expected |
| --- | --- |
| iPhone cold/closed/background; locked after first unlock | Persisted active A → B: bikes A, spaces B; complete spoken result once; no forced foreground |
| Change destination B → C; reverse; end/cancel; relaunch | Same saved personal shortcut uses new role; ended ride never revives |
| No journey | Bikes nearest favourite with a recent permitted location; spaces saved destination; missing/cleared role fails |
| Zero, missing, stale, offline, removed dock | Distinct wording; only real zero yields integer 0; no route substitution |
| No location permission | Active/explicit/saved-destination queries work; nearest favourite explains missing location |
| AirPods, with and without ongoing audio | Correct route; full answer exactly once; normal system audio handling |
| Watch with phone reachable | Confirm newest selection, especially immediately after changing/clearing destination |
| Watch with phone unavailable, Watch network available | Direct lookup; explicit last-synced wording; record actual execution device |
| Watch with neither network nor companion | Meaningful failure, no old numerical fallback |
| Late context after end/clear; multiple active journeys | No resurrection or arbitrary route choice |
| Built-in phrases and exact personal names | Correct action; useful speech rather than bare number or duplicate speech |

## API references

- [App Intent result with value, dialog and view](https://sosumi.ai/documentation/appintents/intentresult/result(value:dialog:view:))
- [Authentication policy](https://sosumi.ai/documentation/appintents/appintent/authenticationpolicy)
- [ShortcutsLink](https://sosumi.ai/documentation/appintents/shortcutslink)
- [TfL count/timestamp clarification](https://techforum.tfl.gov.uk/t/bikepoint-api-clarifications/2732)

The installed SDK was used for source verification. Documentation availability alone is not evidence that Siri routing or Watch independence has passed.

## Follow-up: no journey and shortcut-install buttons

A physical iPhone report confirmed the app-qualified spaces phrase works during an active journey. With no journey and no saved Siri destination, the action correctly has no station to query; choose **Preferences → Siri & Shortcuts → Saved Siri destination** to enable that case. The screenshot showed an “unknown NSError” diagnostic for this expected setup failure. `SiriAvailabilityError` now also conforms to `CustomLocalizedStringResourceConvertible`, preserving the setup explanation across the App Intents process boundary while still returning no number. The setup screen explains the missing destination next to its picker. Rebuild and retest the spoken failure on the phone; local checks cannot prove Siri's speech.

For installation buttons, author the two one-action personal shortcuts once on an installed app, name them **How many spaces** and **How many bikes**, test them, and use **Share → Copy iCloud Link**. App buttons can open those real links so users confirm the preconfigured shortcut in Shortcuts without building or naming it. No links/buttons are fabricated before those tested templates exist. The current `ShortcutsLink` opens discovery only. Legacy `INUIAddVoiceShortcutButton` uses `INShortcut`/SiriKit intents or user activities, rather than accepting our `AppIntent` directly; it is not a drop-in installation button for these actions.

References: [share shortcuts](https://support.apple.com/guide/shortcuts/share-shortcuts-apdf01f8c054/ios), [localized error description](https://sosumi.ai/documentation/foundation/customlocalizedstringresourceconvertible), [INShortcut](https://sosumi.ai/documentation/intents/inshortcut-swift.enum).

Follow-up verification: 68 Siri checks and 125 Journey checks passed; iPhone, Watch Debug/Release and both widget extension source checks passed. `rtk git diff --check` passed. No Xcode build was run.
