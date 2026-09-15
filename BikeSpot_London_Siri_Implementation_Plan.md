# BikeSpot London — hands-free Siri availability plan

**Prepared:** 16 September 2026  
**Audience:** Codex working in the existing BikeSpot London repository  
**Primary goal:** Speak current bike availability at the user's start dock and current return-space availability at their destination dock, without navigating through the app.  
**Default delivery scope:** Phases 0–5 in section 11. Section 12 contains optional follow-on work.

> **Instructions to Codex:** Inspect the existing repository, then implement the core scope in small, buildable increments. Reuse the app's BikePoint client, dock models, favourites, journey selection, persistence, Watch integration and design components. Do not stop after producing another plan. Preserve existing intent identifiers and saved Shortcuts. Verify APIs against the installed SDK, keep existing deployment targets, run available builds/tests, and identify physical-device checks that remain outstanding. Do not invent Apple APIs, BikePoint fields, backend endpoints, dock identities or live counts.

## 1. The experience to deliver

The two primary commands are:

| User says | Dock to query | Information to speak |
|---|---|---|
| **“Hey Siri, how many spaces?”** | The selected **destination** docking station | Available working return spaces. |
| **“Hey Siri, how many bikes?”** | The selected **start** docking station | Available bikes for hire. |

The dock is resolved **when the command runs**. Changing the selected destination must change the answer without making the user rebuild their shortcut.

Illustrative conversations, using fictional dock names and synthetic counts:

> **User:** “Hey Siri, how many spaces?”  
> **Siri:** “There are six spaces at Warwick Row, your destination.”
>
> **User:** “Hey Siri, how many bikes?”  
> **Siri:** “There are eight bikes and five e-bikes at Stonecutter Street, your start dock.”
>
> **User:** “Hey Siri, how many spaces?”  
> **Siri:** “There are no spaces at Warwick Row, your destination. From your nearest alernate docks, Buckingham Gate has five spaces and Kings Gate House has 3 spaces.”

These examples are not real availability or production defaults. Never hard-code their station names or counts.

### Product boundaries

Prioritise the one-question, one-answer experience. The user may be cycling with their phone in a pocket. A successful lookup should not require opening a screen, tapping a choice, or repeatedly naming the dock.

The normal response should contain the **requested count, the dock name and its role**, in one short sentence. Add a second clause only for something material, such as all available bikes being electric or data being unavailable. Do not read out the entire dock record.

The query is read-only: it must not change the route, swap its direction, select another dock, begin tracking, start a workout or launch navigation.

**Not in scope:** bike hire/payment, reservations, unlocking bikes, background voice monitoring, a custom speech recogniser, an LLM service, a new routing engine, a new Live Activity implementation, or redesigning the rest of the app. No prediction that a space will still exist when the rider arrives.

## 2. Exact phrases: distinguish App Shortcuts from personal shortcuts

This distinction is part of the implementation, not a documentation footnote.

Apple's developer-provided App Shortcut phrase model uses the application-name placeholder. Separately, Apple documents invoking a user-created shortcut by saying its name.[^app-shortcuts][^siri-names] Build both paths:

| Path | Intended invocation | Setup |
|---|---|---|
| Built-in App Shortcut | “How many spaces in BikeSpot London?” | App installed; destination configured. |
| Built-in App Shortcut | “How many bikes in BikeSpot London?” | App installed; start configured. |
| Personal shortcut named **How many spaces** | **“Hey Siri, how many spaces?”** | User creates a shortcut containing the destination-spaces action. |
| Personal shortcut named **How many bikes** | **“Hey Siri, how many bikes?”** | User creates a shortcut containing the start-bikes action. |

The personal shortcuts are the explicit route to the user's preferred short wording. They must call the **dynamic role-based actions**, not contain a dock ID copied from the current selection.

Do not include “Hey Siri” in a registered phrase or shortcut title. Do not claim the app automatically owns generic phrases without setup. Exact speech recognition, routing and spoken output must be tested on the target devices and Siri language. Provide the app-qualified phrases as fallbacks.

### Personal shortcut recipes to include in the app's help

**How many spaces**

1. In Shortcuts, create a new shortcut and add BikeSpot London's **Get Spaces at Destination** action.
2. Leave it using the app's selected destination; do not replace it with an explicit-dock action.
3. Name the shortcut **How many spaces** and test it using Siri.

**How many bikes**

1. Create another shortcut with BikeSpot London's **Get Bikes at Start** action.
2. Leave it using the app's selected start dock.
3. Name it **How many bikes** and test it using Siri.

Both should initially contain just the relevant action. Verify that Siri speaks the meaningful dialog once, rather than only the returned number or duplicate speech. Do not add “Open App”, “Show Result”, microphone capture or custom speech synthesis as prerequisites.

The app must not silently install personal shortcuts or fabricate an iCloud sharing link. An app-shortcuts link is a discovery aid, not proof that these personal shortcuts have been created. Apple provides `ShortcutsLink` to open the app's page in Shortcuts.[^shortcuts-link]

## 3. Phase 0 audit: fit the existing app

Before implementation, identify the actual project/workspace, schemes, SDK versions and minimum iOS/watchOS versions. Do not assume a repository path or that the app has already implemented all the concepts below.

| Area | Inspect and reuse |
|---|---|
| Existing Siri integration | App Intents, providers, legacy SiriKit code, metadata, entities, localisation and shortcut identities. |
| Availability | BikePoint models, parser, HTTP client or backend adapter, cache, error handling and attribution. |
| Dock selection | Start/destination fields, saved journeys, favourites, active/tracked journey, map selection, navigation and reset behaviour. |
| Persistence | Durable stores, migration rules, process boundaries, App Groups and protected storage. |
| Watch | Existing watchOS targets, dock selection, direct networking, Watch Connectivity, complications and any activity/tracking feature. |
| Tests and UI | Existing dependency injection, test fixtures, SwiftUI components, accessibility conventions and settings layout. |

Write a short implementation note mapping existing types to the responsibilities in this plan. Preserve equivalents rather than creating parallel Siri-only versions. Keep unrelated refactoring out of scope.

Do not add a new extension, entitlement, permission, background mode or package unless the chosen architecture demonstrably needs it. Do not raise the minimum OS just to access optional iOS 27 features. A runtime availability check does not make an unknown symbol compile in an older SDK.

**Audit output:** concrete types to reuse, the execution process for each intent, required storage access, migration decisions, build commands and the first testable vertical slice.

## 4. Resolve the correct start and destination

### 4.1 Define terms clearly

In this plan, “dock” in the UI means a **docking station/BikePoint**, not one individual locking slot. “Spaces” means the number of usable empty return slots at that station.

Keep these concepts distinct:

- **Current journey:** an explicitly selected/started/tracked journey in the existing app, with a defined lifecycle.
- **Default Siri docks:** durable start/destination selections that the user has explicitly configured for times when there is no current journey.
- **Viewed dock:** a map pin or details screen the user happens to be browsing. This is not automatically a Siri selection.

Reuse an existing authoritative start/destination pair where its semantics already match. Do not introduce competing settings that can disagree with it.

### 4.2 Resolution rules

Implement this decision table in a single testable resolver:

| Situation | Required behaviour |
|---|---|
| Explicit-dock action has a valid station ID | Use that station; do not consult route defaults. |
| There is one authoritative current journey with the requested role populated | Use that journey's start for bikes, or destination for spaces. |
| There is a current journey but its requested role is missing/invalid | Report that role as unavailable or unconfigured. Do not mix in a dock from a different default route. |
| There is no current journey and the requested default Siri dock is configured | Use the configured default for that role. |
| No selection exists | Give a short setup message; do not guess a dock. |
| Multiple journeys exist without one active selection | Do not choose the first or most recently viewed journey. Report that a journey needs selecting. |
| A selected dock was removed or cannot be resolved | Report the selected dock as unavailable; retain its identity for repair rather than silently redirecting. |
| Start and destination intentionally reference the same station | Allow this. A round trip is valid. |

The two hands-free actions have **no required dock parameter** and must not start a station-selection conversation during normal use. A separate explicit-dock action may use Siri's normal parameter resolution.

Do not substitute the nearest station, the first favourite, a recently viewed pin, or a station with better availability. If the selected destination has zero spaces, answer zero for that destination. Alternative-dock suggestions are a separate optional feature.

### 4.3 State lifetime and changes

Use the existing journey's completion/cancellation lifecycle to stop treating it as current. Do not revive an ended journey simply because its record remains in storage.

If the app has no real journey lifecycle, do **not** invent one merely for Siri. Implement a small persistent **Siri start dock / Siri destination dock** selection that remains in effect until explicitly changed or cleared. Label those settings accordingly. A future journey feature can override them using the same resolver.

Do not auto-swap morning/evening directions, infer destinations from time or location, or expire a manually configured default overnight. Where an existing “reverse journey” action exists, its committed result should update Siri consistently, with no separate Siri-only route reversal.

Persist the selected IDs and a revision/change marker before reporting a successful update in the UI. Read an atomic snapshot at invocation. Capture the resolved ID, role and selection revision with the lookup request so a response cannot combine a count from one station with another station's name.

If the selection changes while a request is in flight, discard the obsolete result and resolve/fetch once more within the same overall deadline, or report that the selection changed. Never let a slow request overwrite a newer selection or continue retrying indefinitely.

### 4.4 Storage and process boundaries

Use stable provider IDs, not display names, array indices or newly generated per-query UUIDs. Station renames should not invalidate saved references. Keep a last-known display name only as a helpful fallback label, not evidence of current availability.

The store must work from a cold intent invocation with no screen loaded. Do not depend on a scene, a selected tab, an `onAppear` callback or a view model that only exists in memory.

Share state through the existing persistence mechanism. If separate processes need an App Group, verify membership and access deliberately. An iPhone App Group is **not** a synchronisation channel to the physical Apple Watch; use the existing companion-state transfer mechanism where needed. Watch handling is specified in section 9.

Do not auto-migrate the first two favourites into start/destination. Migrate existing explicit role selections only. Clearing a selection must stay cleared after relaunch or synchronisation.

## 5. Shared availability service and correct BikePoint interpretation

### 5.1 Architecture

```text
Siri / Shortcuts
       |
Thin App Intent adapter
       |
Dock-role resolver -> durable selection snapshot
       |
Existing BikePoint client / backend / cache
       |
Validated availability snapshot + provenance
       |
Deterministic formatter
       |
Spoken dialog + typed count + optional result card
```

Keep selection, parsing, freshness and response wording outside the intent and SwiftUI view types. Inject the clock, store and data client for deterministic tests. Reuse the app's concurrency patterns; avoid blocking network calls and unnecessary main-thread work.

Suggested responsibilities, not mandatory new type names:

| Responsibility | Purpose |
|---|---|
| `SiriDockContextStore` | Read/write the authoritative selection or a small adapter over the existing store. |
| `DockRoleResolver` | Resolve start/destination or an explicit station ID. |
| `DockAvailabilityService` | Obtain and normalise an availability response using the existing client. |
| `DockAvailabilityFormatter` | Build consistent spoken and display wording. |
| `BikeDockEntity` and query | Represent a station for configurable Shortcuts actions. |

### 5.2 Use the existing provider path

TfL documents `GET /BikePoint/{id}` for a particular station and `/BikePoint` for the catalogue with availability. Its `/BikePoint/Search` response does **not** include occupancy properties; resolve the result's ID and retrieve availability separately.[^tfl-api]

Use the existing backend when the app already has one. Do not create a second direct-to-TfL path or expose backend secrets. Where the existing client talks directly to TfL, reuse that architecture instead of adding a new server just for this feature. Fetch only what the existing API can efficiently provide; do not invent a batch endpoint or change authentication conventions.

### 5.3 Count semantics

Inspect actual project fixtures and the current provider response. Preserve the existing model's external contract while fixing any demonstrated parser errors with tests.

| Field/concept | Intended use |
|---|---|
| `NbEmptyDocks` | Return-space count for “How many spaces?” |
| `NbBikes` | Reported total available-bike count for the default “How many bikes?” action; verify the current parser's semantics. |
| `NbStandardBikes` | Standard/non-electric bikes, when supplied. |
| `NbEBikes` | Electric bikes, when supplied. |
| `NbDocks` | Capacity/diagnostic information, **not** the available-space answer. |
| Station operational flags/status | Determine whether availability can be used for the requested operation; verify meaning and handling in the existing provider model. |

TfL's clarification identifies `NbEmptyDocks` as returnable spaces and `NbStandardBikes` as hireable non-electric bikes; it says docks known to be out of service are excluded from availability counts. Its API documentation also allows the total capacity to differ from bikes plus spaces because of broken docks.[^tfl-counts][^tfl-api]

**Product choice:** “bikes” means all available bikes by default, not silently standard-only. Where a trustworthy breakdown is available, briefly mention electric bikes; explicitly say “all electric” when that is the only available type. Preserve an existing user-facing contract if the app already defines a different persistent preference, but document that decision and name the type in the answer. Do not take the meaning from a temporary list/map filter.

### 5.4 Parser and validation rules

Treat the following as implementation requirements:

- Parse properties by key, never by array position. Handle the provider's string values explicitly. Unknown properties should not break decoding.
- Missing, malformed, negative or conflicting duplicate values are **unknown/invalid**, not zero. Preserve zero as a valid count.
- Never calculate spaces as `NbDocks - NbBikes`. Unavailable hardware must not become fictional return spaces.
- Do not subtract a “broken docks” estimate from the supplied availability a second time.
- Do not manufacture a missing standard/electric breakdown. An inconsistent breakdown may be omitted while retaining an independently valid total; a contradictory requested count must not be presented confidently.
- Do not reject a sound requested count solely because an unrelated optional field is absent. Conversely, do not ignore a confirmed station closure or a status that prohibits the requested operation.
- Represent station status as operational, unavailable or unknown unless the existing model has more precise states. Do not default a missing status flag to “closed” or claim a specific closure reason without evidence.
- Validate provider identity: a response for a different station must never be used for the requested ID.

For operational flags such as installed/locked indicators, inspect the actual API contract and existing code before assigning meanings. An unknown flag is not licence to invent an operational state. Where operation status cannot be established, use “TfL reports…” wording rather than claiming the app has independently verified the station.

### 5.5 Normalised snapshot

Use existing domain types with a small adapter where possible. Retain at least:

| Concept | Meaning |
|---|---|
| Station identity | Stable ID and canonical display name. |
| Resolved role | Start, destination or explicit station; selection source/revision. |
| Counts | Total bikes, standard bikes, electric bikes and empty return spaces, each optional until validated. |
| Operational state | Known restrictions and uncertainty affecting the requested operation. |
| Provenance | Provider/backend and whether data came from a fresh request or permitted cache. |
| Retrieval timestamps | Original upstream retrieval time where known, plus client receipt time. |
| Provider timestamps | Preserved separately, with their documented meaning rather than an assumed observation time. |
| Outcome | Usable count, no selection, invalid selection, station unavailable, requested count missing, stale cache or network/provider failure. |

Do not mutate this snapshot while the formatter or snippet is using it.

## 6. Freshness, deadlines and failures

### 6.1 Do not confuse retrieval time with observation time

TfL cautions against treating BikePoint's `modified` field as a guaranteed freshness timestamp; a later explanation suggests it can reflect detected property changes.[^tfl-counts] Therefore, an unchanged station must not automatically become “stale” just because that field is old, and fetching an old cache entry again must not make it “fresh”.

Track when your app/backend actually retrieved the upstream response separately from provider change metadata. Display **“Checked…”** for a retrieval timestamp, not **“Updated…”** unless the underlying field truly means that. Where feed age is unknown, prefer **“TfL reports six spaces…”** and do not claim second-by-second observation accuracy.

A current report is not a reservation. Explain once in setup that availability can change before arrival; avoid repeating a long disclaimer on every successful query.

### 6.2 Bounded request policy

Suggested initial product defaults to validate against the existing service, not Apple or TfL guarantees:

| Setting | Initial choice |
|---|---|
| Retrieval policy | Attempt a current lookup unless an upstream-retrieved snapshot is no more than 30 seconds old. |
| Overall app lookup deadline | Approximately 8 seconds, including any bounded retry; measure on devices. |
| Cached fallback beyond that freshness policy | No numerical fallback in the core voice action. Explain that current availability could not be checked. |
| Ongoing work | None after completion or cancellation. No polling loop. |

Preserve original cache timestamps across app/backend/Watch layers. A recent download of a backend snapshot whose upstream retrieval age is unknown is not sufficient to label it newly checked; fix the metadata or describe the limitation. Respect upstream rate limits, HTTP cache headers and the existing client's cancellation behaviour.

The 30-second threshold is an application reuse policy, not a claim about TfL's publication cadence. Adapt it if the actual backend contract requires a different value and record why.

Coalesce equivalent in-flight requests where the existing client supports it. Avoid parallel duplicate calls from Siri, the snippet and the UI. A failed network request must not become a zero count, “dock full” or “no bikes”. Do not log raw credentials or full personal route context.

### 6.3 Failure behaviour

| Condition | Required spoken meaning |
|---|---|
| Destination not configured | “You haven't selected a destination dock in BikeSpot London.” |
| Start not configured | “You haven't selected a start dock in BikeSpot London.” |
| Multiple current journeys without an active selection | “Choose a current journey in BikeSpot London before checking availability.” |
| Selected station removed/unresolvable | “Your selected destination dock is unavailable. Update it in BikeSpot London.” |
| Known unavailable station | “Market Square, your destination, is currently unavailable for returns.” Only specify returns when supported by status. |
| No network/timeout/provider failure | “I couldn't check spaces at Market Square right now.” |
| Only an old cached count exists | “I couldn't get current space availability at Market Square.” |
| Valid station but missing requested metric | “The space count for Market Square is unavailable.” |
| Protected selection cannot be read | Respect the system's authentication flow; do not substitute another dock. |

Use suitable localised intent errors or another SDK-supported failure result that does not emit a numerical success value. Test the actual spoken error path; a raw enum case or generic “something went wrong” is not acceptable as the only user experience.

## 7. App Intents and App Shortcuts

### 7.1 Core actions

These are proposed names; retain existing equivalent identifiers and parameter contracts.

| Action | Parameters | Behaviour |
|---|---|---|
| `GetSpacesAtDestinationIntent` | None | Resolve the current destination, then speak its validated return-space count. |
| `GetBikesAtStartIntent` | None | Resolve the current start, then speak its validated bike count. |
| `GetSpacesAtDockIntent` | Required `BikeDockEntity` | Configurable explicit-station lookup in Shortcuts. Does not change the destination. |
| `GetBikesAtDockIntent` | Required `BikeDockEntity` | Configurable explicit-station lookup in Shortcuts. Does not change the start. |

The first two are the release priority. Implement the explicit-dock actions using the same services, not another parser. Make their names and descriptions unambiguous in the Shortcuts action picker.

Use `ProvidesDialog` for spoken results. On validated success, return a typed integer count through `ReturnsValue` as well, so other shortcuts do not have to parse prose. A compact SwiftUI snippet can accompany the result.[^dialog][^return-value][^intent-results]

Do not return `0`, `-1` or a previous count on failure. Zero is a successful, meaningful availability result. Use one consistent supported return shape for the success branches and a tested localised failure path for other outcomes. Do not weaken error semantics merely to satisfy Swift's opaque return-type constraints.

### 7.2 Phrase registration

Register a small set of phrases in the existing `AppShortcutsProvider`. Suggested templates:

```text
Destination spaces:
  How many spaces in <applicationName>
  Check destination spaces in <applicationName>

Start bikes:
  How many bikes in <applicationName>
  Check start dock bikes in <applicationName>
```

In Swift, use the actual `\(.applicationName)` interpolation rather than the literal placeholder above. These are templates to compile and test, not a promise of unrestricted natural-language matching.[^app-shortcuts]

Prioritise the two role-based actions in discovery. Explicit-dock actions can remain available in Shortcuts without enumerating the entire station catalogue as spoken phrases. If adding a phrase containing a dock, use a supported entity parameter and bounded meaningful suggestions, not arbitrary free-text parsing.

Use the app's supported name/synonym configuration rather than assuming Siri will hear “BikeSpot” and “BikeSpot London” identically. Preserve any existing legacy shortcut compatibility from the app's earlier branding; do not rename intent identities casually.

### 7.3 Station entities

Implement `BikeDockEntity` as an adapter over the existing catalogue model with a stable provider ID, readable name and distinguishing area information where useful. The entity/query system allows the framework to resolve stored identifiers; Apple's App Intents examples also demonstrate searching entities by text.[^entities]

Use existing search/normalisation for names, punctuation and aliases. Return real candidates when a name is ambiguous. A stale explicit ID must fail helpfully instead of resolving to a different similarly named station. Handle renamed stations using their unchanged IDs.

Suggested stations can include favourites and the selected start/destination. Do not fetch fresh counts just to populate a parameter picker or put changing availability into the station's identity. Refresh App Shortcut parameter suggestions when relevant catalogue/favourite identities change, not every time one bike is hired.[^app-shortcuts]

### 7.4 Background execution and privacy

Configure read-only intents to complete without bringing the app to the foreground using APIs supported by the project's SDK and deployment targets. Keep intentional app navigation separate. Inspect the appropriate execution-mode API rather than copying a new availability annotation blindly.

Review `authenticationPolicy` and the protected storage used by the selected route.[^authentication] Public station counts and the user's personal destination are not the same privacy category. Preserve existing privacy controls; do not lower file/keychain protection or add an insecure duplicate route store to bypass an unlock requirement.

Apple notes that a shortcut which opens an app can require unlocking the device.[^siri-names] Avoid unnecessary foreground actions, but do not promise universal locked-device execution. Test after first unlock, after reboot before first unlock, and with different Siri-on-lock-screen settings. Respect system restrictions.

No new microphone, location, workout, notification or background-audio permission is needed for the product design of these two ID-based lookups. Audit actual framework requirements rather than adding unrelated capabilities. Siri handles the voice interaction; the app must not listen continuously or take over audio playback.

## 8. Spoken answers, setup and result card

### 8.1 Response rules

Generate dialog deterministically from the same validated snapshot as the number returned to Shortcuts. Localise strings and singular/plural forms; avoid concatenating ungrammatical fragments.

| Outcome | Synthetic example |
|---|---|
| Several return spaces | “There are six spaces at Market Square, your destination.” |
| One return space | “There's one space at Market Square, your destination.” |
| Zero return spaces | “There are no spaces at Market Square, your destination.” |
| Several bikes, known mix | “There are eight bikes at Riverside Road, your start dock, including two electric bikes.” |
| All bikes electric | “There are three bikes at Riverside Road, your start dock, all electric.” |
| One bike, unknown type | “There's one bike at Riverside Road, your start dock.” |
| Zero bikes | “There are no bikes at Riverside Road, your start dock.” |
| Provider report with uncertain operational state/feed age | “TfL reports six spaces at Market Square, your destination.” |

Explicit-dock actions omit “your start dock”/“your destination” unless that relationship has actually been established. A default used outside a current journey can say “your saved destination” to distinguish it from an active ride. Count, role and spoken name must all refer to the same resolved station.

Do not call a station “full” unless that conclusion is supported: “no spaces” is sufficient. Do not say “you're guaranteed a space”, “you'll be fine”, or predict future availability. Do not announce “only one left” and launch an unsolicited alternative search.

Avoid reading raw provider IDs, irrelevant district suffixes, percentages or full capacity unless needed for disambiguation. Retain enough name information to distinguish genuinely different stations.

### 8.2 Small setup surface

Add a compact **Siri & Shortcuts** section, reusing existing settings/route UI:

| Item | Behaviour |
|---|---|
| Start dock | Show/edit the explicit default selection or link to the existing authoritative field. |
| Destination dock | Same for destination. |
| Current selection explanation | Show when a current journey overrides defaults. |
| Try bikes / Try spaces | Run the same lookup and show the result for setup; do not implement a separate network path. |
| Short phrase help | Include the two personal-shortcut recipes from section 2. |
| Discover app shortcuts | Use a supported Shortcuts link/tip where appropriate. |

Do not require starting a ride just to use a saved start or destination. Do not force a user with only one configured role to configure the other before its corresponding command works.

Where existing dock detail menus support selection, reuse or add concise **Use as start** and **Use as destination** actions. They must explicitly update the authoritative role selection, not just move the map. Avoid duplicate controls if equivalent actions already exist.

Do not label a button “Added to Siri” unless the app can genuinely establish that state through a supported mechanism. A help screen should describe setup, not pretend to perform it.

### 8.3 Optional result card within the core integration

A small card may show the requested count prominently, the unit (“spaces” or “bikes”), dock name, role and “Checked…” timestamp/uncertainty. Use the app's existing colours and components, accessible text/symbols, Dynamic Type and VoiceOver. Do not rely on colour alone.

The card is a **snapshot**. It must not make its own network request, start polling or look like a live countdown. Any supported open-dock affordance should use existing navigation and refresh the station on opening; viewing it is not required to complete the spoken answer.

## 9. iPhone, AirPods and Apple Watch

The first release target is reliable iPhone Siri, including voice-only use through the user's existing audio route. Apple also supports invoking shortcuts by name on Apple Watch, but app-specific execution and dependencies still need validation.[^siri-names]

Because BikeSpot has a Watch use case, inspect the watchOS target rather than assuming a phone intent automatically gives equivalent independent Watch behaviour.

### Watch implementation requirements

Reuse the existing Watch selection, networking and synchronisation architecture. Make the two lookups available on watchOS where the actual SDK/target supports them. Do not create a new tracking/activity feature as a prerequisite.

A Watch lookup must either obtain fresh availability through an existing Watch-capable client or use a tested, bounded phone-assisted path. A complication's old snapshot is not a substitute for a current availability response. If neither path is available, say the check could not be completed.

For companion-state transfer, Apple's Watch Connectivity documentation describes application-context updates as replacing the previous context.[^watch-connectivity] Merge the Siri-selection fields into the app's existing payload rather than sending a new dictionary that drops unrelated state.

Keep stable dock IDs, explicit clears, selection source, schema version and a revision/change marker in the shared context. Reuse the app's conflict rules. Do not revive a cleared/ended journey from a late message or overwrite a newer selection with an older snapshot.

Do not assume context transfer is instantaneous. Prefer the existing authoritative active selection; define whether Watch edits are supported. If the last confirmed context cannot safely identify the current destination, fail clearly or identify it explicitly as the **last synced** destination. Do not silently present an uncertain older destination as current. Test changing the destination on the phone immediately before asking the Watch.

### Required device observations

Record the device, OS, app version, Siri language, input phrase, actual execution device, chosen station, spoken result, app foregrounding and latency for each test. Separate:

- iPhone Siri with the app closed/backgrounded and the phone locked after first unlock.
- Siri through AirPods, including interaction with ongoing audio and whether the complete answer is spoken once.
- Watch Siri with the paired phone reachable, then phone unavailable but Watch network access present.
- Watch with neither a usable network nor a reachable companion; recently changed/cleared selections and stale context.

Do not claim independent Watch support unless that scenario actually passes. Surface and document platform/account restrictions honestly. Conduct interaction tests while stationary, not while riding in traffic.

## 10. Test plan and acceptance criteria

### 10.1 Automated tests

Use fictional dock names and recorded/sanitised payload fixtures, plus injected time/network results. Do not make unit tests depend on live TfL counts.

| Area | Minimum cases |
|---|---|
| Role resolution | Bikes uses start; spaces uses destination; no role inversion; explicit dock overrides context. |
| Context precedence | Current journey overrides defaults; missing role on a current journey does not borrow a different route's dock; no active journey uses explicit defaults. |
| Selection lifecycle | End/cancel/clear, relaunch, rename by stable ID, same start/destination, multiple journeys, invalid/deleted dock, destination change during request. |
| No guessing | No selection never falls back to nearest/first favourite/last viewed station; zero availability never changes the selected dock. |
| Property decoding | Reordered keys, string integers, zero, missing/invalid/negative values, duplicate conflicts, unknown keys and wrong station ID. |
| Count correctness | Capacity differs from bikes plus spaces; no capacity-minus-bikes fallback; no double subtraction; partial/mismatched bike-type breakdown. |
| Operational state | Confirmed unavailable for the requested operation; unknown/missing flags; unrelated optional fields absent. |
| Freshness | Valid recent retrieval; old cache; recent backend download of old upstream data; unknown upstream retrieval age; old `modified` but newly retrieved report. |
| Network | Offline, timeout, cancellation, rate limit, server/auth errors, malformed response, bounded retries and coalescing where implemented. |
| Output | Singular/plural, zero phrasing, all-electric bikes, provider-report wording, correct name/role/count, localised error and no numerical success on failure. |
| Persistence/Watch | Migration only from explicit roles, atomic reads, revision ordering, explicit clears, context payload merge and no resurrection of ended journeys. |
| Regression | Existing favourites, dock lists, widgets, Watch components and saved Shortcuts continue working. |

A useful synthetic parser fixture is `NbDocks=30`, `NbBikes=8`, `NbEmptyDocks=6`, `NbStandardBikes=6`, `NbEBikes=2`. The spaces answer must be **6**, not **22**; the bike answer is **8**, with **2** electric. This fixture intentionally leaves capacity unavailable and must not be “repaired” by the parser.

### 10.2 Siri end-to-end acceptance

The feature is ready only when the following are demonstrated on supported physical devices, or explicitly recorded as unverified/blocking:

1. Configure start A and destination B. The personal shortcut **How many bikes** reads A; **How many spaces** reads B.
2. Change destination from B to C. Invoke the same personal shortcut without editing it; it reads C.
3. Force a cold/background invocation. The action resolves persisted state and completes without depending on a loaded screen.
4. With valid zero availability, Siri speaks zero/no availability for the selected station and does not change the route.
5. With no network and an old cache, Siri does not read an old count as current or return zero as a substitute.
6. With an unconfigured role, Siri gives a concise setup message without an interactive station list or silently borrowing another dock.
7. App-qualified phrases and personal-shortcut names both route correctly. Siri speaks the full meaningful result once.
8. Locked-phone and Watch cases are tested separately; working phone behaviour is not reported as proof of Watch independence.

Use XCTest or the repository's existing test framework. Add intent-specific testing tools only where available in the installed SDK; do not make an optional new framework a dependency for basic unit tests.

## 11. Implementation sequence

### Phase 0 — Audit and first vertical slice

Identify the existing types, SDK constraints and build commands. Prove one role-based lookup can use the existing service from a cold invocation with a synthetic test result. Record how Siri chooses the execution process.

**Exit:** A concrete integration map and buildable intent/service seam; no unrelated architecture rewrite.

### Phase 1 — Authoritative dock context

Implement the resolver and the smallest necessary persistence/settings changes. Add default roles only where the app lacks equivalent explicit selections. Integrate existing journey lifecycle and revision handling.

**Exit:** Selection tests pass; changing/clearing the UI selection is reflected in a subsequent cold lookup.

### Phase 2 — Availability and response correctness

Reuse/refactor the BikePoint client into the shared service. Add validated counts, operation status, freshness provenance, bounded networking and deterministic response formatting.

**Exit:** Parser/freshness tests pass, including zero versus unknown and broken-capacity fixtures.

### Phase 3 — Siri actions and short-phrase setup

Implement the two role-based intents, typed outputs, dialogs and built-in phrase templates. Add the two explicit-dock actions through the same service. Include the personal-shortcut recipes and test one installed shortcut end to end early.

**Exit:** The exact two personal shortcut names call dynamic roles and provide useful spoken answers; failures do not emit a success count.

### Phase 4 — Setup, snapshot card and existing Watch integration

Finish the compact setup/help surface and result card. Wire the same context/service into the existing Watch target where supported. Preserve companion payloads, privacy settings and legacy shortcuts.

**Exit:** Setup is understandable; Watch-supported and Watch-blocked scenarios are identified through builds/device tests rather than assumptions. Do not withhold a working phone implementation because a separate Watch scenario is blocked.

### Phase 5 — Regression and release handoff

Run affected builds and automated tests, complete the physical-device matrix where accessible, and update implementation notes and user help. Verify metadata extraction, localisation and preserved deployment targets.

**Exit:** Provide a precise implemented/verified/unverified summary, actual build/test results and any remaining release blockers.

## 12. Optional follow-on work — not prerequisites

### Explicit standard-bike and electric-bike queries

Add dedicated actions or a clearly named bike-type parameter using the same service. Report the chosen type explicitly, and fail rather than substituting a different type when a requested count is unknown.

### Alternative docks when the destination is full

Expose a separate **Find spaces near my destination** action. Centre the search on the destination, not automatically on the rider's location. Return a small number of operational stations with verified return spaces, using existing search/routing facilities.

Do not auto-change the destination, fabricate cycling times from straight-line distance, promise capacity on arrival or turn every zero-count answer into a long list. Changing the destination should be an explicit user action.

### Voice changes to start/destination

Add separate setter intents only after read-only queries are reliable. Resolve ambiguity before persisting; speak the selected station; respect authentication; never make a lookup action a hidden setter.

### Additional iOS 27 integration

Investigate contextual or conversational features only after verifying actual SDK APIs, schema applicability and device behaviour. The two core commands must not depend on Apple Intelligence, an unverified bike-sharing schema or iOS 27-only functionality. Do not force bike counts into an unrelated system schema or claim that adopting an annotation guarantees arbitrary speech understanding.

## 13. Required Codex handoff

At completion, report changed files and key reused components; the final role-resolution/freshness rules; any migration or privacy changes; available shortcut action names; exact build/test commands and results; and which Siri/Watch checks remain unverified.

Include the two personal-shortcut recipes in repository documentation. Clearly state that example counts in tests/help are synthetic. Do not claim deployment or real-device validation without doing it. Do not create fake `.shortcut` downloads or sharing URLs as a substitute for working actions.

### Prompt to start implementation

```text
Read BikeSpot_London_Siri_Implementation_Plan.md and implement Phases 0–5 in this repository.
Prioritise the hands-free dynamic actions: “How many spaces” uses the selected destination dock; “How many bikes” uses the selected start dock.
Reuse the existing BikePoint client, selection/persistence, App Intents and Watch architecture. Preserve saved Shortcuts and deployment targets.
Include setup instructions for personal shortcuts with those exact names. Never treat missing/stale data as zero or silently substitute another dock.
Work in small buildable increments, run the affected builds/tests, and report physical-device checks still needed. Treat section 12 as optional follow-on work.
Implement the feature rather than producing another plan.
```

## References

Platform references support the integration mechanisms; selection precedence, wording, scope and cache thresholds above are proposed product requirements. Codex must confirm exact API signatures and availability against the repository's installed SDK. References checked on 16 September 2026.

[^siri-names]: Apple Support, [Use Siri to run shortcuts with your voice](https://support.apple.com/en-gb/guide/shortcuts/apd07c25bb38/ios). Invoking a shortcut by name, supported device examples and app-opening/locked-device behaviour.

[^app-shortcuts]: Apple Developer, [Implement App Shortcuts with App Intents — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10170/). Application-name placeholders, custom intents, parameterised phrases and parameter refresh.

[^shortcuts-link]: Apple Developer, [ShortcutsLink](https://developer.apple.com/documentation/appintents/shortcutslink) and [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts). Discovery surfaces for the app's actions.

[^dialog]: Apple Developer, [ProvidesDialog](https://developer.apple.com/documentation/appintents/providesdialog). Returning dialog from an action.

[^return-value]: Apple Developer, [ReturnsValue](https://developer.apple.com/documentation/appintents/returnsvalue). Returning a typed value from an action.

[^intent-results]: Apple Developer, [Bring your app's core features to users with App Intents — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10210/). Spoken dialog and SwiftUI snippet results.

[^entities]: Apple Developer, [Get to know App Intents — WWDC25](https://developer.apple.com/videos/play/wwdc2025/244/). Entity representation, queries and results.

[^authentication]: Apple Developer, [AppIntent.authenticationPolicy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy). Intent execution authentication policy.

[^watch-connectivity]: Apple Developer, [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity). Companion communication and application-context replacement behaviour.

[^tfl-api]: Transport for London, [Unified API specification](https://api.tfl.gov.uk/swagger/docs/v1) and [API documentation](https://tfl.gov.uk/info-for/open-data-users/api-documentation). BikePoint lookup/search and occupancy properties; capacity discrepancies.

[^tfl-counts]: TfL Tech Forum, [BikePoint API Clarifications](https://techforum.tfl.gov.uk/t/bikepoint-api-clarifications/2732). TfL response dated 26 May 2023 on return spaces, standard bikes, out-of-service docks and timestamp interpretation. This is an operational clarification, not a guaranteed real-time freshness SLA; verify against the current provider contract.
