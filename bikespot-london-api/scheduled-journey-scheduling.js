const crypto = require("crypto");

function localDateParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const weekdayMap = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  return {
    weekday: weekdayMap[lookup.weekday],
    dateKey: `${lookup.year}-${lookup.month}-${lookup.day}`,
    time: `${lookup.hour}:${lookup.minute}`,
  };
}

function parseMinutesSinceMidnight(rawValue) {
  if (typeof rawValue !== "string") return null;
  const match = rawValue.trim().match(/^([01]\d|2[0-3]):([0-5]\d)$/);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

function scheduledWindowMinutes(startTime, endTime) {
  const startMinutes = parseMinutesSinceMidnight(startTime);
  const endMinutes = parseMinutesSinceMidnight(endTime);
  if (startMinutes === null || endMinutes === null) return null;
  const diff = (endMinutes - startMinutes + 24 * 60) % (24 * 60);
  return diff === 0 ? 24 * 60 : diff;
}

function scheduledRunKey(journey, date = new Date()) {
  const parts = localDateParts(date, journey.timezone || "Europe/London");
  return `${parts.dateKey}:${journey.startTime}`;
}

function manualScheduledJourneyRunKey(date = new Date(), identifier = crypto.randomUUID()) {
  return `manual:${date.toISOString()}:${identifier}`;
}

function scheduledJourneyStartDecision(journey, date = new Date()) {
  if (journey.enabled === false) {
    return { canStart: false, reason: "disabled" };
  }
  if (journey.deletedAt) {
    return { canStart: false, reason: "deleted" };
  }

  const parts = localDateParts(date, journey.timezone || "Europe/London");
  const runKey = `${parts.dateKey}:${journey.startTime}`;
  const base = { parts, runKey };
  if (!journey.weekdays?.includes(parts.weekday)) {
    return { canStart: false, reason: "weekday_mismatch", ...base };
  }
  if (parts.time !== journey.startTime) {
    return { canStart: false, reason: "time_mismatch", ...base };
  }

  if (journey.activeRun?.phase) {
    if (journey.activeRun.runKey === runKey) {
      return { canStart: false, reason: "already_active_for_run", ...base };
    }
    const activeStartedAt = journey.activeRun.startedAt
      ? new Date(journey.activeRun.startedAt)
      : null;
    if (activeStartedAt && !Number.isNaN(activeStartedAt.getTime())) {
      const activeParts = localDateParts(
        activeStartedAt,
        journey.timezone || "Europe/London"
      );
      if (activeParts.dateKey === parts.dateKey) {
        return { canStart: false, reason: "already_active_today", activeParts, ...base };
      }
    }
  }

  if (Array.isArray(journey.pausedRunKeys) && journey.pausedRunKeys.includes(runKey)) {
    return { canStart: false, reason: "run_paused", ...base };
  }

  return { canStart: true, reason: "eligible", ...base };
}

function shouldEndScheduledJourneyWindow(journey, date = new Date()) {
  // The configured end time is the latest time the rider can reach the start
  // dock. Once they have arrived, the journey remains active until the end dock
  // is reached (or it is stopped for another reason such as holiday mode).
  if (journey.activeRun?.phase !== "start") return false;

  const parts = localDateParts(date, journey.timezone || "Europe/London");
  if (parts.time === journey.endTime) return true;

  const activeStartedAt = journey.activeRun.startedAt
    ? new Date(journey.activeRun.startedAt)
    : null;
  if (!activeStartedAt || Number.isNaN(activeStartedAt.getTime())) return false;

  const windowMinutes = scheduledWindowMinutes(journey.startTime, journey.endTime);
  if (windowMinutes === null) return false;

  return date.getTime() - activeStartedAt.getTime() >= windowMinutes * 60 * 1000;
}

module.exports = {
  localDateParts,
  manualScheduledJourneyRunKey,
  scheduledWindowMinutes,
  scheduledJourneyStartDecision,
  scheduledRunKey,
  shouldEndScheduledJourneyWindow,
};
