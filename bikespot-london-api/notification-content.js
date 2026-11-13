function countText(count, unit) {
  return `${count} ${unit}${count === 1 ? "" : "s"}`;
}

function availabilityTitle(name, display, count, minimum = 0) {
  const metric = display === "spaces" ? "Spaces" : display === "eBikes" ? "E-Bikes" : "Bikes";
  if (count === 0) return display === "spaces" ? `${name} Is Full` : `No ${metric} at ${name}`;
  return `${metric} ${count < minimum ? "Low" : "Available"} at ${name}`;
}

function availabilityBody(name, display, count, minimum = 0, recovery = false) {
  const unit = display === "spaces" ? "space" : display === "eBikes" ? "e-bike" : "bike";
  const amount = count === 0 ? `no ${unit}s` : countText(count, unit);
  const below = count > 0 && count < minimum ? `, below your minimum of ${minimum}` : "";
  return `${name} ${recovery ? "now " : ""}has ${amount} available${below}.`;
}

function destinationMessage(name, data, kind, startName) {
  const spaces = data?.emptySpaces;
  const known = Number.isInteger(spaces) && spaces >= 0;
  const availability = known
    ? `${name} has ${spaces === 0 ? "no spaces" : countText(spaces, "space")} available.`
    : `Space availability at ${name} is currently unavailable.`;
  if (kind === "halfway") return {
    title: `Halfway to ${name}`,
    body: known
      ? `You’re halfway to ${name}, which has ${spaces === 0 ? "no spaces" : countText(spaces, "space")} available.`
      : `You’re halfway to ${name}. ${availability}`,
  };
  if (kind === "approach") return { title: `Approaching ${name}`, body: availability };
  return {
    title: known && spaces === 0 ? `${name} Is Full` : `Journey to ${name}`,
    body: `${startName ? `You’ve reached ${startName}. ` : ""}${availability}`,
  };
}

module.exports = { countText, availabilityTitle, availabilityBody, destinationMessage };
