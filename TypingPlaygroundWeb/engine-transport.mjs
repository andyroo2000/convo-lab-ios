export async function engineFetch(path, options = {}) {
  if (options.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  const result = await window.webkit.messageHandlers.typingEngine.postMessage({
    path,
    body: options.body ?? null,
  });
  return new Response(JSON.stringify(result), {
    status: result.error ? 503 : 200,
  });
}
