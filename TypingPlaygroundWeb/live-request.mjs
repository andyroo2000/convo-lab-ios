import { engineFetch } from "./engine-transport.mjs";
// Coalesce typing while inference is in flight instead of building a queue of
// obsolete GPU jobs. A stale response can never change the notebook.
export class LiveRequest {
  version = 0;
  busy = false;
  pending = null;
  timer = null;

  constructor(receive, fail, expanded = false) {
    this.expanded = expanded;
    this.receive = receive;
    this.fail = fail;
  }

  cancel() {
    this.version += 1;
    clearTimeout(this.timer);
    this.pending = null;
  }

  schedule(reading, immediate = false, boundaries = []) {
    this.cancel();
    const version = this.version;
    this.timer = setTimeout(
      () => {
        this.pending = { reading, version, immediate, boundaries };
        this.run();
      },
      immediate ? 0 : 250,
    );
  }

  async run() {
    if (this.busy || !this.pending) return;
    const job = this.pending;
    this.pending = null;
    this.busy = true;
    const started = performance.now();
    try {
      const response = await engineFetch("/api/v1/convert", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          reading: job.reading,
          expanded: this.expanded,
          ...(job.boundaries.length && { boundaries: job.boundaries }),
        }),
        signal: AbortSignal.timeout(65000),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error);
      if (job.version === this.version)
        this.receive(job, result, performance.now() - started);
    } catch (error) {
      if (job.version === this.version) this.fail(error);
    } finally {
      this.busy = false;
      this.run();
    }
  }
}
