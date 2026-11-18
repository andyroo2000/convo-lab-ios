import { LiveRequest } from "./live-request.mjs";

export class ExpandedMenu {
  reading = null;

  constructor(session, elements, update) {
    this.session = session;
    this.elements = elements;
    this.request = new LiveRequest(
      (job, result, elapsed) => {
        if (!session.atCaret() || session.reading() !== job.reading) return;
        update(job.reading, result);
        elements.status.textContent =
          "More choices ready · ↑ ↓ choose · ← → sections · Enter to commit.";
        elements.metrics.textContent = `${result.engineMs.toFixed(1)} ms engine · ${elapsed.toFixed(0)} ms menu expansion`;
      },
      () => {
        this.reading = null;
        elements.status.textContent =
          "Could not load more choices. Current choices and text are kept; press Space to retry.";
      },
      true,
    );
  }

  reset() {
    this.reading = null;
    this.request.cancel();
  }

  load(reading, boundaries = []) {
    const key = JSON.stringify([reading, boundaries]);
    if (key === this.reading) return;
    this.reading = key;
    this.elements.status.textContent = "Looking for more choices…";
    this.request.schedule(reading, true, boundaries);
  }
}
