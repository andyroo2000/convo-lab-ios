export async function engineFetch(path, options = {}) {
  if (options.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  const json = await window.webkit.messageHandlers.typingEngine.postMessage({
    path,
    body: options.body ?? null,
  });
  const result = JSON.parse(json);
  return new Response(json, {
    status: result.error ? 503 : 200,
  });
}
