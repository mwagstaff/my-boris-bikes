const fs = require("node:fs");

// Claims survive server restarts and Live Activity token changes. Claim before
// sending: ambiguous transport failures must not cause a second halfway alert.
class JourneyNotificationReceipts {
  constructor(file) {
    this.file = file;
    this.entries = new Map(fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : []);
  }

  save() {
    const temporary = `${this.file}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify([...this.entries]), { mode: 0o600 });
    fs.renameSync(temporary, this.file);
  }

  async sendOnce(key, send) {
    const now = Date.now();
    for (const [id, timestamp] of this.entries) {
      if (now - timestamp > 24 * 60 * 60 * 1000) this.entries.delete(id);
    }
    if (this.entries.has(key)) return false;
    this.entries.set(key, now);
    try { this.save(); } catch (error) { this.entries.delete(key); throw error; }
    try {
      await send();
      return true;
    } catch (error) {
      // A definite APNs rejection is safe to retry; a lost response is not.
      if (Number(error?.apns?.statusCode) >= 400) {
        this.entries.delete(key);
        this.save();
      }
      throw error;
    }
  }
}

module.exports = { JourneyNotificationReceipts };
