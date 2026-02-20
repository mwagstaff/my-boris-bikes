# My Boris Bikes Live Activity Server

Node.js server for managing live activities with APNS push notifications.

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
- `POLL_INTERVAL_MS` - Polling interval (default: 30000)
- `SESSION_TIMEOUT_MS` - Session timeout (default: 14400000)
- `LOG_LEVEL` - Logging level (default: info)
- `LOG_DIR` - Log directory (default: ./logs)
- `APNS_KEY_ID` - Apple Push Notification service key ID
- `APNS_TEAM_ID` - Apple team ID
- `APNS_KEY_PATH` - Path to APNS private key
- `APNS_TOPIC` - APNS topic

## Endpoints

- `POST /live-activity/start` - Start tracking a dock
- `POST /live-activity/end` - Stop tracking a dock
- `POST /live-activity/test` - Start test mode with simulated data
- `POST /live-activity/test/end` - Stop test mode
- `GET /healthcheck` - Health check
- `GET /status` - Server status and metrics
- `GET /live-activity/status` - Active sessions info
- `GET /metrics` - Prometheus metrics endpoint

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
