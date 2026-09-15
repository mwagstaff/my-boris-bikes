// Progress is an estimate supplied by the companion's location service, never by the dock poller.
function updateJourneyProgress(session, value, now = Date.now() / 1000) {
  if (session.scheduledJourneyPhase !== "end" || !value || typeof value !== "object") return false;
  const { percent, remainingMeters, updatedAtEpochSeconds } = value;
  if (!Number.isInteger(percent) || percent < 0 || percent > 100 ||
      !Number.isFinite(remainingMeters) || remainingMeters < 0 ||
      !Number.isFinite(updatedAtEpochSeconds) || updatedAtEpochSeconds > now + 10 ||
      updatedAtEpochSeconds < now - 120) return false;
  if (updatedAtEpochSeconds <= (session.journeyProgress?.updatedAtEpochSeconds ?? 0)) return false;
  session.journeyProgress = { percent, remainingMeters, updatedAtEpochSeconds };
  return true;
}

// A repeated registration or dock refresh must not restart the ride clock.
function rideStartedAtForPhase(phase, previousSession, requestedValue, now = Date.now() / 1000) {
  if (phase !== "end") return null;
  const valid = value => typeof value === "number" && Number.isFinite(value) && value > 0
    && value <= now + 10 && value >= now - 8 * 3600;
  if (previousSession?.scheduledJourneyPhase === "end") {
    if (valid(previousSession.rideStartedAtEpochSeconds)) return previousSession.rideStartedAtEpochSeconds;
    // Older in-flight sessions have no reliable collection timestamp.
    return valid(requestedValue) ? Math.min(requestedValue, now) : null;
  }
  return valid(requestedValue) ? Math.min(requestedValue, now) : now;
}

module.exports = { updateJourneyProgress, rideStartedAtForPhase };
