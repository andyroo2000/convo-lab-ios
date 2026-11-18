import { engineFetch } from "./engine-transport.mjs";
export function watchReadiness(onState) {
  const status = document.getElementById("engine-status");
  const retry = document.getElementById("retry-engine");
  const composition = document.getElementById("composition");
  const examples = document.querySelectorAll("[data-reading]");
  let previous;
  let stopped = false;
  let timer;
  let generation = 0;

  function show(state) {
    if (state === previous) return;
    previous = state;
    composition.disabled = state !== "ready";
    for (const button of examples) button.disabled = state !== "ready";
    retry.hidden = state !== "error";
    status.dataset.state = state;
    const messages = {
      loading: "Getting the model ready… You can start typing in a moment.",
      ready: "Ready to write · Neural conversion",
      error: "Couldn’t prepare the model. Your writing is still here.",
    };
    status.textContent = messages[state];
    onState(state);
  }

  async function check(run = generation) {
    try {
      const response = await engineFetch("/api/v1/engine", {
        signal: AbortSignal.timeout(3000),
      });
      if (!response.ok) throw new Error("Status unavailable");
      const result = await response.json();
      if (stopped || run !== generation) return;
      show(
        ["ready", "loading"].includes(result.state) ? result.state : "error",
      );
    } catch {
      if (stopped || run !== generation) return;
      show("error");
    }
    if (!stopped) timer = setTimeout(() => check(run), 1000);
  }

  retry.addEventListener("click", async () => {
    clearTimeout(timer);
    const run = ++generation;
    show("loading");
    try {
      const response = await engineFetch("/api/v1/engine/retry", {
        method: "POST",
        signal: AbortSignal.timeout(3000),
      });
      if (!response.ok) throw new Error("Retry unavailable");
    } catch {
      if (stopped || run !== generation) return;
      show("error");
    }
    if (!stopped) check(run);
  });
  window.addEventListener("pagehide", () => {
    stopped = true;
    clearTimeout(timer);
  });
  window.addEventListener("pageshow", (event) => {
    if (!event.persisted) return;
    stopped = false;
    check(++generation);
  });
  show("loading");
  check();
}
