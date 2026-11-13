# BikeSpot London Live Activity Server

Node.js server for managing live activities with APNS push notifications.

> Compatibility: the published app keeps its existing bundle identifiers, API path, database name, and environment-variable names. The legacy-looking values below are intentional and must remain unchanged for existing installations and deployment configuration.

## Running the Server

```bash
npm install
node server.js
```

## Deployment

Deploy to remote server using launchd:

```bash
export DEPLOY_HOST=mikes-mac-mini
./deploy.zsh
```

The deploy script:
- Auto-detects entry file (prefers `server.js`, falls back to `index.js`)
- Syncs files via rsync (excludes `node_modules`, logs, etc.)
- Installs production dependencies on server
- Creates/updates launchd service for automatic startup and restart on crash
- Restarts the service with new code

To undeploy (remove service but keep files):

```bash
export DEPLOY_HOST=mikes-mac-mini
./undeploy.zsh
```

## Testing

### Test Metrics Endpoint

```bash
./test-metrics.sh
```

This will show a preview of the Prometheus metrics and example curl commands for testing device token tracking.

## Logging

The server uses Winston for logging with automatic daily rotation:

- **Location**: `logs/` directory (auto-created)
- **Retention**:
  - General logs: 3 days
  - Error logs: 7 days
- **Max file size**: 20MB per log file

### Log Files

- `server-YYYY-MM-DD.log` - All logs (info, warnings, errors)
- `error-YYYY-MM-DD.log` - Error logs only

### Viewing Logs

**Quick Commands (using helper script):**

```bash
./logs.sh tail                    # Watch live server logs
./logs.sh error                   # Watch live error logs
./logs.sh search BikePoints_316   # Search for specific dock
./logs.sh search "Session expired" # Search for expired sessions
./logs.sh list                    # List all log files
```

**Manual Commands:**

```bash
# Tail today's logs
tail -f logs/server-$(date +%Y-%m-%d).log

# Tail error logs
tail -f logs/error-$(date +%Y-%m-%d).log

# Search logs for specific dock
grep "BikePoints_316" logs/server-*.log

# Search for expired sessions
grep "Session expired" logs/server-*.log

# View logs from last 100 lines
tail -100 logs/server-$(date +%Y-%m-%d).log
```

### Log Levels

Set via environment variable:
```bash
LOG_LEVEL=debug node server.js
```

Available levels: `error`, `warn`, `info` (default), `debug`

## Configuration

Environment variables:
- `PORT` - Server port (default: 3010)
- `POLL_INTERVAL_MS` - Polling interval (default: 15000)
- `SESSION_TIMEOUT_MS` - Session timeout default (default: 7200000)
- `MAX_NOTIFICATION_WINDOW_MS` - Hard cap on notification window (default: 7200000)
- `LOG_LEVEL` - Logging level (default: info)
- `LOG_DIR` - Log directory (default: ./logs)
- `APNS_KEY_ID` - Apple Push Notification service key ID
- `APNS_TEAM_ID` - Apple team ID
- `APNS_KEY_PATH` - Path to APNS private key
- `APNS_TOPIC` - Live Activity APNS topic (for example `com.example.app.push-type.liveactivity`)
- `APNS_BACKGROUND_TOPIC_MY_BORIS_BIKES` - App bundle topic for alert/background pushes (preferred)
- `APNS_BACKGROUND_TOPIC` - Legacy alias still supported for backward compatibility
- `MONGODB_URI_BIKESPOT_LONDON` - MongoDB connection string for scheduled journeys (preferred)
- `MONGODB_URI_MY_BORIS_BIKES` / `MONGODB_URI` / `MONGO_URI` - Legacy MongoDB connection string fallbacks
- `MONGODB_DB_NAME` - Mongo database name (default: `my_boris_bikes`)
- `SCHEDULED_JOURNEYS_COLLECTION` - Collection name (default: `scheduled_journeys`)
- `BACKGROUND_IMAGES_DIR` - Absolute directory for the background catalogue and published images (default: `data/backgrounds` beside `server.js`). Use a persistent directory outside the deployment checkout for independently managed images.

## Endpoints

- `GET /backgrounds` - Versioned background catalogue, cached by HTTP clients for five minutes
- `GET /backgrounds/images/:file` - Immutable, content-versioned JPEG or PNG
- `GET /BikePoint` - TfL proxy for all docks (applies admin overrides)
- `GET /Place/:dockId` - TfL proxy for a single dock (applies admin overrides)
- `GET /admin` - Admin UI for dock value overrides
- `GET /admin/api/docks` - Dock list for admin UI
- `GET /admin/api/overrides` - Current overrides
- `POST /admin/api/overrides` - Set override `{ dockId, standardBikes, eBikes, emptySpaces, latitude?, longitude? }`
- `DELETE /admin/api/overrides/:dockId` - Clear override
- `POST /live-activity/start` - Start tracking a dock
- `POST /live-activity/session/update` - Update tracked session settings (focused metric/thresholds)
- `POST /live-activity/end` - Stop tracking a dock
- `GET /scheduled-journeys` - List scheduled journeys for a device
- `POST /scheduled-journeys` - Create a scheduled journey
- `PUT /scheduled-journeys/:id` - Update a scheduled journey
- `DELETE /scheduled-journeys/:id` - Soft-delete a scheduled journey
- `POST /scheduled-journeys/:id/activate` - Manually activate the current run
- `POST /scheduled-journeys/:id/stop` - Pause only the current active run and end related sessions
- `POST /scheduled-journeys/:id/phase` - Mark the active run as watching the start or end dock
- `POST /scheduled-journeys/:id/complete` - Clear the active run after destination arrival
- `POST /scheduled-journeys/device/register` - Register device, APNs, and ActivityKit push-to-start tokens
- `POST /live-activity/test` - Start test mode with simulated data
- `POST /live-activity/test/end` - Stop test mode
- `GET /healthcheck` - Health check
- `GET /status` - Server status and metrics
- `GET /live-activity/status` - Active sessions info
- `GET /metrics` - Prometheus metrics endpoint

## Updating the app backgrounds

This feature needs one API deployment and one app release to install the downloader. After that, images can be added, replaced, reordered or removed on the server without restarting the API or releasing the app. The supplied `data/backgrounds` collection contains 37 approved London images: the original 12 plus the 25 from collection 02. The original 12 remain bundled as offline fallbacks; the additional images download on demand.

The API reads `catalog.json` for each request. The publishing tool writes versioned image files first and atomically replaces the catalogue last. Keep a separate **source folder containing the complete desired collection**. JPEG/PNG filenames are stable image IDs: for example, `LondonEyeHeader.jpg`. The local starter set is in `../output/london-background-source/`.

From the API directory, publish the complete source folder:

```sh
node scripts/publish-backgrounds.js /path/to/background-source
```

The destination is `BACKGROUND_IMAGES_DIR`, or `data/backgrounds` by default. You can also pass a destination directory as the second argument. On the deployed server, the publisher and the API must use the same published directory. Copy the source folder to that server and run the command there to update the live collection.

- **Replace:** overwrite an image in the source folder, keeping its filename, then republish. Changed bytes receive a new SHA-256 filename, so phones cannot confuse them with an old cached version.
- **Add:** put a new JPEG/PNG in the source folder and republish. New IDs require no Swift code or asset-catalog changes.
- **Remove:** delete it from the source folder and republish. The tool replaces the whole catalogue; a source folder with one image publishes a one-image collection.
- **Reorder:** the publisher uses filename order. To choose another order, rearrange the `images` array in a copy of `catalog.json`, then atomically rename the copy into place. IDs, filenames, hashes and byte counts must remain unchanged.

Use landscape compositions around 1536 × 1024. IDs accept letters, numbers, `_` and `-` (up to 80 characters). The catalogue supports up to 100 images. Each JPEG/PNG must be at most 5 MiB; the app accepts dimensions up to 4096 × 4096, applies orientation metadata and downsamples to a maximum 2048-pixel edge for display. The publisher checks format headers, IDs and file size; preview new images before publishing.

Old versioned files are deliberately retained for phones with older catalogues. Do not immediately delete them during publication. A malformed or incomplete catalogue returns HTTP 503 instead of advertising missing files; clients keep their last valid catalogue.

For production, place published files outside the checkout so a later code deployment cannot overwrite the live catalogue. Set `BACKGROUND_IMAGES_DIR` in the API service environment and seed that directory with the contents of `data/backgrounds` during the initial deployment. Source photos and generated review pages are not served by these routes.

### App caching and rotation

The app selects one background per foreground visit and shares it across tabs. Temporary inactivity does not rotate it. It checks for catalogue changes at most every six hours while being used; failed catalogue requests retry no sooner than five minutes later. Refreshed catalogue entries become eligible on the next visit, so a catalogue refresh does not change the current scene halfway through a visit.

Only the selected remote image is downloaded. Each completed download is checked against its expected size, SHA-256 and decoded image dimensions before an atomic cache write. Unchanged versions of the original 12 images reuse bundled assets without downloading them. Local images and the catalogue survive app restarts in `Library/Caches`, with a 50 MiB image limit per API environment. Older cached images are evicted as needed, and iOS may also purge the cache.

Offline or failed downloads keep the currently displayed background. The bundled collection remains available for first launch, cache removal, older API deployments or an empty remote catalogue. Image and catalogue requests are cancelled when the app backgrounds. The approved light/dark appearance and accessibility behaviour apply equally to bundled and downloaded images.

Debug builds provide **Preferences → Debug → Test Background Images** to force a catalogue refresh, advance the rotation, download even an unchanged bundled image, reload from disk without networking, and clear this server's background cache. The screen shows a live preview, image source, validation result and storage details. See [the background test guide](../ios/BackgroundTests/README.md) for the full validation workflow.

### Live Activity Availability Alerts

When a live activity is active, the server now tracks transitions for the selected primary metric:
- `bikes`
- `eBikes`
- `spaces`

Availability warnings now include alternatives in the same notification. For example:

- **No Bikes at Home** — `Home has no bikes available. Alternatives: Station has 6 bikes; Park has 4 bikes.`
- **Spaces Low at Office** — `Office has 2 spaces available, below your minimum of 5. Alternatives: Station has 6 spaces.`
- **Spaces Available at Office** — `Office now has 6 spaces available.`

Existing zero-availability, below-minimum change and recovery triggers remain in
place. Notifications use the selected bikes/e-bikes/spaces filter and resolve
current recipient aliases at send time. Up to three alternatives retain saved
order (including saved docks with zero availability), then fill remaining slots
with nearby open docks with availability. Failed or empty alternative lookups
leave the primary message intact; they never generate a separate alert.

Journey notifications:

| Event | Single notification |
| --- | --- |
| Scheduled start | `Journey to Office` — `Home has 8 bikes and 2 e-bikes available. Live updates have started.` Included in the Live Activity start push; no second availability push. |
| Collection dock arrival | `Journey to Office` — `You’ve reached Home. Office has 5 spaces available.` |
| Collection arrival with full destination | `Office Is Full` — `You’ve reached Home. Office has no spaces available. Alternatives: Station has 6 spaces; Park has 4 spaces.` |
| Halfway | `Halfway to Office` — `You’re halfway to Office, which has 2 spaces available. Alternatives: Station has 6 spaces; Park has 4 spaces.` |
| Destination approach | `Approaching Office` — `Office has 2 spaces available. Alternatives: Station has 6 spaces; Park has 4 spaces.` |
| Final / standalone dock arrival | `Arrived at Office` — `You’ve reached Office.` |

The app requests collection-arrival text from `POST /live-activity/arrival-message`
with `deviceId`, `dockPreferences`, `startDock`, and `endDock`. This endpoint
composes text without sending a push. iOS delivers one local notification and
passes `arrivalNotificationHandled: true` during the session migration to suppress
the server snapshot. If the content request fails, the local arrival message says
destination availability is unavailable. Manual transitions still receive one
server destination snapshot. The phase-update endpoint no longer sends a separate
watching/arrival alert. Full collection-arrival consolidation requires the updated
API **and** iOS app; older clients retain their local welcome plus one destination
snapshot until updated. Deploy the API before releasing the app.

The halfway alert uses the existing location-derived journey progress, during the
riding phase, on the first fresh update at or above 50% and below 100%. It applies
to scheduled and ad-hoc journeys and fetches destination availability at send time.
Missing data is described as unavailable, never as zero. Alternatives appear only
below the configured minimum. Completed/ended journeys cannot emit a late milestone.

`LOG_DIR/journey-notification-receipts.json` holds hashed per-device/per-ride
milestone claims for 24 hours. Preserve it across deployments/restarts. Claims
prevent duplicate halfway alerts across concurrent requests, token changes and
restoration with the same ride start time. Explicit APNs rejection permits retry;
an ambiguous network failure retains the claim to avoid duplicate delivery.
Monitor `journey_halfway` events in the existing push-event dashboard/logs and
`apns_pushes_total`. A readable/writable receipt directory is required; check logs
for receipt/send failures. The app/API build and tests cannot verify physical-device
notification presentation or Apple Intelligence summaries; exercise those on an
actual journey, including offline pickup and a halfway crossing.

The app should provide both the selected primary metric and minimum thresholds when calling `POST /live-activity/start`:

```json
{
  "primaryDisplay": "spaces",
  "minimumThresholds": {
    "bikes": 3,
    "eBikes": 2,
    "spaces": 5
  }
}
```

### Custom sample notifications

From your Mac, run this from `bikespot-london-api`:

```sh
node scripts/sample-notification.js --remote sky
```

This runs the installed helper over SSH in `~/dev/boris-bikes-api` on Sky,
keeping the signing key and device tokens on the server. It prompts for title,
body and a target device. Text arguments also work with `--remote sky`.
Use `--remote sky --check` to verify the credential and registration files
without sending. After changing the helper, copy it to the server's
`~/dev/boris-bikes-api/scripts/sample-notification.js`; no service restart is needed.

Run `node scripts/sample-notification.js` from the API directory on a machine
with its APNs signing key and registered `complication-tokens.json` (or the
configured `COMPLICATION_TOKENS_PATH`). It prompts for a title, body and one
device, showing masked token prefixes and registration dates. Match the prefix
to your iPhone's app token; the list can include other devices and old installs.
This standalone tool sends one ordinary BikeSpot alert without starting the API,
changing journey state or overriding dock values. It does not add a public endpoint
or appear in the running API's in-memory push-event log; retain the returned APNs ID.

You can also supply text as arguments:

```sh
node scripts/sample-notification.js --title 'Journey to Office' --body 'You have reached Home. Office has 5 spaces available.'
```

For a specific device, save its regular app APNs token in a private text file
(not a Live Activity or push-to-start token), then add
`--token-file /private/path/iphone-token.txt --environment production`.
Use `production` for App Store/TestFlight and `development` for Xcode development
builds. The tool uses the same `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID` and
app-topic environment settings/defaults as the API. Service environment settings
must also be present in the shell running the tool. There is no automatic resend
or environment fallback, so each successful invocation sends exactly one sample.

Add `--dry-run` to preview the payload without credentials or network access.
For summary comparisons, dismiss previous BikeSpot alerts, lock the iPhone, and
send a sample. Compare it with the original three messages by running the tool
three times. Keep notification-summary and Focus settings consistent. APNs
acceptance does not prove display, speech or Apple Intelligence summarisation;
verify those on the physical device. No sample is sent automatically.

### Notification Stop Conditions

- The app attempts to call `POST /live-activity/end` when a live activity is dismissed/ended.
- The server enforces a hard max notification window (default: 2 hours) even if no explicit end request arrives.
- If `expirySeconds` is supplied by the client, it is capped to this max window.

### Device Token Tracking

All API requests should include the `X-Device-Token` header with the device's unique identifier for tracking unique users. The server automatically tracks unique users over the following time periods:
- 1 minute
- 5 minutes
- 1 hour
- 1 day
- 1 week
- 30 days
- All time

### Prometheus Metrics

The `/metrics` endpoint exposes the following metrics:

**HTTP Metrics:**
- `http_request_duration_seconds` - Histogram of request durations
- `http_requests_total` - Counter of total HTTP requests (by method, route, status)

**Live Activity Metrics:**
- `live_activities_active` - Gauge of currently active live activities
- `live_activities_total` - Counter of live activities started (by build type)
- `live_activities_ended_total` - Counter of live activities ended (by reason: user, expired, error)
- `apns_pushes_total` - Counter of APNS pushes sent (by event, build type, status)
- `dock_polls_total` - Counter of dock polls (by dock ID, status)

**TfL Freshness Metrics:**
- `tfl_data_age_seconds` - Current age of the newest bike-count timestamp in the full `/BikePoint` feed
- `tfl_data_last_modified_timestamp_seconds` - Unix timestamp for that newest bike-count update
- `tfl_data_last_checked_timestamp_seconds` - Unix timestamp when the full `/BikePoint` freshness check last completed
- `tfl_stale_dock_ratio` - Fraction of docks with bike-count data older than 10 minutes
- `tfl_stale_docks_total` / `tfl_docks_checked_total` - Stale dock count and total checked docks
- `tfl_freshness_properties_checked_total` - Count of bike-count timestamp properties checked in the last run

**App Interaction Metrics:**
- `app_actions_total` - Counter of app actions (by action, screen, dock ID/name, build type)
- `dock_stats_total` - Counter of dock-focused actions for `favorite_add`, `dock_tap`, and `live_activity_start` (by action, screen, dock ID/name, build type)

**User Metrics:**
- `unique_users` - Gauge of unique users by device token (by period: 1m, 5m, 1h, 1d, 1w, 30d, all)

**System Metrics:**
- Default Node.js metrics (CPU, memory, event loop, etc.)

## Auto-Expiry Mechanism

Live activities automatically expire using a dual-layer approach:

### Client-Side (Primary)
- Activities are created with a `staleDate` (default: 4 hours, configurable via app)
- iOS automatically dismisses the activity when the stale date is reached
- Works even when the app is not running

### Server-Side (Backup)
- Server tracks each session's start time and expiry duration
- Every 30 seconds, checks for expired sessions
- When expired, sends APNS "end" push with `dismissal-date` to force immediate dismissal
- Ensures cleanup even if client-side fails

This redundancy ensures Live Activities are always removed on time.


### Journey history

`GET /journey-history?deviceId=…` returns `{ entries, hasMore }` with up to 50 completed scheduled runs, newest first. To fetch the next page, pass the last entry's exact ISO timestamp as `before` and its `id` as `afterID`. Cursors retain milliseconds and use IDs to resolve equal timestamps. The response is scoped to the same device identity used by scheduled journeys.

Completed runs are archived idempotently in MongoDB's `journey_history` collection before completion, stop, expiry or schedule deletion clears their active run. The archive retains dock snapshots and start/end timestamps even after deleting the schedule. The device persists ad-hoc and favourite starts locally and merges scheduled history by run ID. Existing discarded trips cannot be backfilled. Deploy this API version alongside the History UI; older servers cannot supply background scheduled history.
