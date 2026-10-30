const test = require("node:test");
const assert = require("node:assert/strict");
const { notificationDockName } = require("../notification-dock-name");

test("notifications use the recipient's alias for the exact dock", () => {
  const preferences = { aliases: { start: "  🏠 Home  ", end: "Office" } };
  assert.equal(notificationDockName(preferences, "start", "Official start"), "🏠 Home");
  assert.equal(notificationDockName(preferences, "end", "Official end"), "Office");
  assert.equal(notificationDockName({ aliases: { start: "Station" } }, "start", "Official"), "Station");
});

test("absent, cleared and unknown aliases fall back without reviving old names", () => {
  for (const preferences of [null, { aliases: {} }, { aliases: { start: "  " } }]) {
    assert.equal(notificationDockName(preferences, "start", "Official"), "Official");
  }
  const preferences = { aliases: { start: "Home" } };
  delete preferences.aliases.start;
  assert.equal(notificationDockName(preferences, "start", "Official"), "Official");
  assert.equal(notificationDockName(preferences, "missing", undefined), undefined);
});
